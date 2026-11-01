/// What one sync with the sync folder did (ADR 0038).
public struct SyncReport: Equatable, Sendable {
    /// Events of this machine's that reached the folder.
    var pushed = 0
    /// Other machines' events applied.
    public var applied = 0
    /// Whether an applied event changed the library.
    public var changed = false
    /// What was wrong with the folder or a log, each log's capped at `maximumProblems` and then
    /// counted on one line.
    public var problems: [String] = []

    /// How many problems one log lists before counting the rest.
    static let maximumProblems = 100
}
