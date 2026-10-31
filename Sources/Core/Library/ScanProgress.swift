/// How far a scan has got. Counts only grow during a scan.
public struct ScanProgress: Equatable, Sendable {
    public enum Stage: Equatable, Sendable {
        /// Listing folders and comparing each audio file's size and mtime with the index, while
        /// reading the new and changed files found so far.
        case walking
        /// Reading the rest of the new and changed files, once every folder is listed.
        case reading
    }

    public var stage = Stage.walking
    /// Audio files the walk has found that the folder's patterns include.
    public var found = 0
    /// Of those, files whose size and mtime match the index.
    public var unchanged = 0
    /// New and changed files to read, which grows until the walk is done.
    public var toRead = 0
    public var read = 0
    public var failed = 0

    /// A stream for a scan's progress that keeps only the newest value, so a scan never waits
    /// on a slow reader such as the UI. Pass the continuation to `LibraryScanner.scan`.
    public static func makeStream() -> (
        stream: AsyncStream<ScanProgress>, continuation: AsyncStream<ScanProgress>.Continuation
    ) {
        AsyncStream.makeStream(of: ScanProgress.self, bufferingPolicy: .bufferingNewest(1))
    }
}
