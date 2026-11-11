/// The track table's visible columns, left to right, with their widths, and its sort.
public struct TrackTableLayout: SettingValue {
    public static let widthRange = 20.0...2000.0

    public var columns: [ColumnLayout]
    public var sortColumn: TrackColumn
    public var sortAscending: Bool

    public init(columns: [ColumnLayout], sortColumn: TrackColumn, sortAscending: Bool) {
        self.columns = columns
        self.sortColumn = sortColumn
        self.sortAscending = sortAscending
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case columns, sortColumn, sortAscending
    }

    public init(from decoder: any Decoder) throws {
        let container = try strictContainer(decoder, CodingKeys.self)
        columns = try container.decode([ColumnLayout].self, forKey: .columns)
        sortColumn = try container.decode(TrackColumn.self, forKey: .sortColumn)
        sortAscending = try container.decode(Bool.self, forKey: .sortAscending)
    }

    public static var typeName: String {
        "a track table layout (columns, sortColumn, sortAscending)"
    }
    public static var kind: SettingKind { .windowState }

    public func problem() -> String? {
        if columns.isEmpty { return "columns is empty; the table needs at least one" }
        if !sortColumn.isSortable { return "sortColumn: \(sortColumn.rawValue) can't be sorted by" }
        return columnsProblem(columns)
    }
}

/// Why a list of columns can't be shown: a column listed twice or a width out of range.
func columnsProblem(_ columns: [ColumnLayout]) -> String? {
    var seen: Set<TrackColumn> = []
    for (index, layout) in columns.enumerated() {
        if !seen.insert(layout.column).inserted {
            return "columns[\(index)]: \(layout.column.rawValue) is listed twice"
        }
        if let problem = widthProblem(layout.width) { return "columns[\(index)]: \(problem)" }
    }
    return nil
}

/// Why a column's width can't be shown: it's outside `TrackTableLayout.widthRange`.
func widthProblem(_ width: Double) -> String? {
    let range = TrackTableLayout.widthRange
    guard !range.contains(width) else { return nil }
    return "width \(width) is outside \(range.lowerBound)...\(range.upperBound)"
}

/// One visible column and its width in points.
public struct ColumnLayout: Codable, Equatable, Sendable {
    public var column: TrackColumn
    public var width: Double

    public init(column: TrackColumn, width: Double) {
        self.column = column
        self.width = width
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case column, width
    }

    public init(from decoder: any Decoder) throws {
        let container = try strictContainer(decoder, CodingKeys.self)
        column = try container.decode(TrackColumn.self, forKey: .column)
        width = try container.decode(Double.self, forKey: .width)
    }
}
