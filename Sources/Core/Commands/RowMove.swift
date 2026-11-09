import Foundation

/// A row movement command, as Searcher's 0029 defines them, apart from any table.
public enum RowMove: Sendable, Equatable {
    case down, up, tenDown, tenUp, first, last, pageDown, pageUp
    /// The first row of the next album, or of the one before the cursor's (ADR 0160).
    case nextAlbum, previousAlbum

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

    /// After `move` in a list of `rowCount` rows with `pageRows` on screen. A plain move selects
    /// the target alone. An extending one keeps the anchor and changes the range from it to the
    /// cursor: rows the old range covered and the new one doesn't are deselected, and rows
    /// selected outside both stay. With no cursor, a move down starts at the first row and a
    /// move up at the last.
    ///
    /// `album` gives each row's album ID, for the album moves; rows with none are one album with
    /// each other, as the album lines group them (ADR 0088). A list without albums passes nil,
    /// and an album move leaves its selection as it is. Past the last album, a move to the next
    /// stays; in the first, a move to the previous goes to its first row.
    public func moved(
        _ move: RowMove, extending: Bool, rowCount: Int, pageRows: Int,
        album: ((Int) -> Int64?)? = nil
    ) -> ListSelection {
        guard rowCount > 0 else { return self }
        if album == nil, move == .nextAlbum || move == .previousAlbum { return self }
        let album = album ?? { _ in nil }
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
                case .nextAlbum:
                    Self.nextAlbumStart(after: min(cursor, last), rowCount: rowCount, album)
                        ?? cursor
                case .previousAlbum: Self.previousAlbumStart(before: min(cursor, last), album)
                }
        } else {
            target =
                switch move {
                case .down, .tenDown, .pageDown, .first, .nextAlbum: 0
                case .up, .tenUp, .pageUp, .last: last
                case .previousAlbum: Self.albumStart(of: last, album)
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

    /// The first row of `row`'s album.
    private static func albumStart(of row: Int, _ album: (Int) -> Int64?) -> Int {
        let id = album(row)
        var start = row
        while start > 0, album(start - 1) == id { start -= 1 }
        return start
    }

    /// The first row after `row`'s album, nil when its album is the last.
    private static func nextAlbumStart(after row: Int, rowCount: Int, _ album: (Int) -> Int64?)
        -> Int?
    {
        let id = album(row)
        var next = row + 1
        while next < rowCount, album(next) == id { next += 1 }
        return next < rowCount ? next : nil
    }

    /// The first row of the album before `row`'s, or of `row`'s own when it's the first.
    private static func previousAlbumStart(before row: Int, _ album: (Int) -> Int64?) -> Int {
        let start = albumStart(of: row, album)
        return start > 0 ? albumStart(of: start - 1, album) : 0
    }
}
