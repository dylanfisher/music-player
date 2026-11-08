import DisplayText

/// What Import Moves… did with a move list (ADR 0026).
public struct MoveListImport: Equatable, Sendable {
    /// Lines whose stats moved to a new path that had none.
    var moved = 0
    /// Lines whose new path had stats of its own, which merged with the old path's.
    var merged = 0
    /// Lines a scan, or an import of the list before, already moved.
    var alreadyDone = 0
    /// The lines that moved nothing, in line order.
    public var problems: [MoveListProblem] = []

    /// One line for the sheet's title.
    public var summary: String {
        "Moved the stats of \(tracks(moved + merged))"
    }

    /// The counts, for the sheet's text.
    public var detail: String {
        var parts = [
            "\(number(moved)) moved", "\(number(merged)) merged with stats the new path had",
            "\(number(alreadyDone)) already moved",
        ]
        parts.append(
            problems.isEmpty
                ? "no problems"
                : "\(number(problems.count)) not moved, listed in the Problems window, where ⌘C"
                    + " copies them")
        return parts.joined(separator: ", ") + "."
    }
}
