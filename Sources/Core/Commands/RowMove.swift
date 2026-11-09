import Foundation

/// A row movement command, as Searcher's 0029 defines them, apart from any table.
public enum RowMove: Sendable, Equatable {
    case down, up, tenDown, tenUp, first, last, pageDown, pageUp

    /// The selection commands' moves, each with whether it extends the selection.
    public static let commands: [CommandID: (move: RowMove, extending: Bool)] = [
        .selectNext: (.down, false), .selectPrevious: (.up, false), .extendDown: (.down, true),
        .extendUp: (.up, true), .tenRowsDown: (.tenDown, false), .tenRowsUp: (.tenUp, false),
        .extendTenRowsDown: (.tenDown, true), .extendTenRowsUp: (.tenUp, true),
        .selectFirst: (.first, false), .selectLast: (.last, false),
        .pageDown: (.pageDown, false), .pageUp: (.pageUp, false),
    ]
}

/// A list's selected rows, the row the keys move from, and the row an extending move keeps.
public struct ListSelection: Equatable, Sendable {
    public var rows: IndexSet
    public var cursor: Int?
    public var anchor: Int?

    public init(rows: IndexSet, cursor: Int?, anchor: Int?) {
        self.rows = rows
        self.cursor = cursor
        self.anchor = anchor
    }

    /// After `move` in a list of `rowCount` rows with `pageRows` on screen. A plain move selects
    /// the target alone. An extending one keeps the anchor and changes the range from it to the
    /// cursor: rows the old range covered and the new one doesn't are deselected, and rows
    /// selected outside both stay. With no cursor, a move down starts at the first row and a
    /// move up at the last.
    public func moved(_ move: RowMove, extending: Bool, rowCount: Int, pageRows: Int)
        -> ListSelection
    {
        guard rowCount > 0 else { return self }
        let last = rowCount - 1
        let page = max(1, pageRows)
        let target: Int
        if let cursor {
            target =
                switch move {
                case .down: cursor + 1
                case .up: cursor - 1
                case .tenDown: cursor + 10
                case .tenUp: cursor - 10
                case .first: 0
                case .last: last
                case .pageDown: cursor + page
                case .pageUp: cursor - page
                }
        } else {
            target =
                switch move {
                case .down, .tenDown, .pageDown, .first: 0
                case .up, .tenUp, .pageUp, .last: last
                }
        }
        let row = min(max(target, 0), last)
        guard extending else { return ListSelection(rows: [row], cursor: row, anchor: row) }
        let anchor = self.anchor ?? cursor ?? row
        var rows = self.rows
        if let cursor {
            rows.subtract(IndexSet(integersIn: min(anchor, cursor)...max(anchor, cursor)))
        }
        rows.formUnion(IndexSet(integersIn: min(anchor, row)...max(anchor, row)))
        return ListSelection(rows: rows, cursor: row, anchor: anchor)
    }
}
