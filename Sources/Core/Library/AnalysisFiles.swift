import Metadata

/// What Analyze Library has done of the library's files and what it has left (ADR 0119).
public struct AnalysisFiles: Sendable {
    /// The files left, in path order, so a pass over a share reads a folder at a time, with the
    /// index's stamp for each.
    public var pending: [(path: String, stamp: FileStamp)]
    /// Files with measures made since the run started.
    public var done: Int
    /// Of `pending`, those the last run couldn't analyze or store.
    public var failed: Int
    /// A run started and didn't go through every file it listed: it was paused, or the app quit.
    public var unfinished: Bool

    public var total: Int { done + pending.count }
}
