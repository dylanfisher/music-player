/// What one scan of a watched folder did.
public struct ScanSummary: Equatable, Sendable {
    /// How many files a scan read at once.
    public enum Readers: Equatable, Sendable {
        case fixed(Int)
        /// Tuned to the volume as the scan ran: each level it settled on, in order, and whether
        /// it was still climbing when the scan ended.
        case tuned([Int], climbing: Bool)
    }

    /// New or changed files read and stored, including those that failed.
    public var read = 0
    /// Files whose read failed in this scan. Their failures are stored with the file.
    public var failed = 0
    /// Files whose size and mtime matched the index, so they weren't read.
    public var unchanged = 0
    /// Files no longer on disk, or no longer included, removed from the index.
    public var removed = 0
    /// Files without an audio extension, which are skipped.
    public var otherFiles = 0
    public var issues: [ScanIssue] = []
    /// Stopped by `ScanControl.cancel`. What was read is kept; nothing was removed.
    public var cancelled = false
    /// Nil when the scan stopped before reading.
    public var readers: Readers?
}
