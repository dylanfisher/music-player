/// The newest journaled edit as Undo Tag Edit asks about it (ADR 0136): which edit it is, the
/// window it was made in, nil when its entry doesn't say, and how many files it holds.
public struct JournaledEdit: Equatable, Sendable {
    /// The edit's entry in the journal.
    public let sequence: Int
    public let origin: TagEditOrigin?
    public let fileCount: Int
}
