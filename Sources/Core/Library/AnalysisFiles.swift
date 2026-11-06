import Metadata

/// What Analyze Library has done of the library's files and what it has left (ADR 0119).
public struct AnalysisFiles: Sendable {
    /// The files left to read, in path order, so a pass over a share reads a folder at a time,
    /// with the index's stamp for each.
    public var pending: [(path: String, stamp: FileStamp)]
    /// Files with measures made since the run started.
    public var done: Int
    /// Files the run couldn't analyze or store, as the index has them now. They aren't in
    /// `pending`: a run carried on doesn't read them again, a run again does.
    public var failed: Int
    /// A run started and didn't go through every file it listed: it was paused, or the app quit.
    public var unfinished: Bool

    /// Files the run has been through, those that failed included.
    public var tried: Int { done + failed }
    public var total: Int { tried + pending.count }
}
