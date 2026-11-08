/// A line of a move list that moved nothing, and why.
public struct MoveListProblem: Equatable, Sendable, CustomStringConvertible {
    /// From 1.
    public var line: Int
    public var reason: String

    public var description: String { lineProblem(line, reason) }
}
