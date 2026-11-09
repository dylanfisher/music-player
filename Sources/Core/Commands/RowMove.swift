import Foundation

/// A row movement command, as Searcher's 0029 defines them, apart from any table.
public enum RowMove: Sendable, Equatable {
    case down, up, tenDown, tenUp, first, last, pageDown, pageUp
    /// The first row of the next album, or of the one before the cursor's (ADR 0161). Only a
    /// list that knows its rows' albums makes these, through `ListSelection.albumTarget` and `moved(to:)`.
    case nextAlbum, previousAlbum

    public var isByAlbum: Bool { self == .nextAlbum || self == .previousAlbum }

    /// The selection commands' moves, each with whether it extends the selection.
    public static let commands: [CommandID: (move: RowMove, extending: Bool)] = [
        .selectNext: (.down, false), .selectPrevious: (.up, false), .extendDown: (.down, true),
        .extendUp: (.up, true), .tenRowsDown: (.tenDown, false), .tenRowsUp: (.tenUp, false),
        .extendTenRowsDown: (.tenDown, true), .extendTenRowsUp: (.tenUp, true),
        .selectFirst: (.first, false), .selectLast: (.last, false),
        .pageDown: (.pageDown, false), .pageUp: (.pageUp, false),
        .nextAlbum: (.nextAlbum, false), .previousAlbum: (.previousAlbum, false),
        .extendToNextAlbum: (.nextAlbum, true), .extendToPreviousAlbum: (.previousAlbum, true),
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

    /// After `move` in a list of `rowCount` rows with `pageRows` on screen. With no cursor, a
    /// move down starts at the first row and a move up at the last. An album move leaves the
    /// selection as it is: the list finds its row with `albumTarget`, then calls `moved(to:)`.
    public func moved(_ move: RowMove, extending: Bool, rowCount: Int, pageRows: Int)
        -> ListSelection
    {
        guard rowCount > 0, !move.isByAlbum else { return self }
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
                case .nextAlbum, .previousAlbum: cursor
                }
        } else {
            target =
                switch move {
                case .down, .tenDown, .pageDown, .first, .nextAlbum: 0
                case .up, .tenUp, .pageUp, .last, .previousAlbum: last
                }
        }
        return moved(to: min(max(target, 0), last), extending: extending)
    }

    /// With `row` as the cursor. A plain move selects it alone. An extending one keeps the
    /// anchor and changes the range from it to the cursor: rows the old range covered and the
    /// new one doesn't are deselected, and rows selected outside both stay.
    public func moved(to row: Int, extending: Bool) -> ListSelection {
        guard extending else { return ListSelection(rows: [row], cursor: row, anchor: row) }
        let anchor = self.anchor ?? cursor ?? row
        var rows = self.rows
        if let cursor {
            rows.subtract(IndexSet(integersIn: min(anchor, cursor)...max(anchor, cursor)))
        }
        rows.formUnion(IndexSet(integersIn: min(anchor, row)...max(anchor, row)))
        return ListSelection(rows: rows, cursor: row, anchor: anchor)
    }

    /// The row `move`, an album move, goes to from `cursor` in a list of `rowCount` rows: the
    /// first row of the next album, or of the one before the cursor's. `album` reads a row's
    /// album ID; rows with none are one album with each other, as the album lines group them
    /// (ADR 0088). With no cursor, the next album is the first row's, the previous the last
    /// row's. Nil past the last album; in the first, the previous is its first row.
    public static func albumTarget(
        _ move: RowMove, from cursor: Int?, rowCount: Int,
        isolation: isolated (any Actor)? = #isolation, album: (Int) async throws -> Int64?
    ) async rethrows -> Int? {
        guard rowCount > 0 else { return nil }
        let last = rowCount - 1
        switch move {
        case .nextAlbum:
            guard let cursor else { return 0 }
            let row = min(cursor, last)
            let id = try await album(row)
            var next = row + 1
            while next < rowCount, try await album(next) == id { next += 1 }
            return next < rowCount ? next : nil
        case .previousAlbum:
            let start = try await albumStart(of: min(cursor ?? last, last), album)
            guard cursor != nil else { return start }
            return start > 0 ? try await albumStart(of: start - 1, album) : 0
        default:
            preconditionFailure("\(move) isn't an album move")
        }
    }

    /// The first row of `row`'s album.
    private static func albumStart(
        of row: Int, isolation: isolated (any Actor)? = #isolation,
        _ album: (Int) async throws -> Int64?
    )
        async rethrows -> Int
    {
        let id = try await album(row)
        var start = row
        while start > 0, try await album(start - 1) == id { start -= 1 }
        return start
    }
}
