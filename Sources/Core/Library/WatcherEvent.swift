/// What the watcher's scans are doing, so the window can refresh as rows arrive and show what
/// went wrong.
public enum WatcherEvent: Sendable {
    /// A scan of the watched folder at this path is under way and may have stored rows. Sent at
    /// most once per `LibraryWatcher.progressIntervalSeconds`.
    case scanning(folder: String, ScanProgress)
    case scanned(folder: String, ScanSummary)
    /// The scan stopped because the database failed. What it stored before then stays.
    case scanFailed(folder: String, reason: String)
}
