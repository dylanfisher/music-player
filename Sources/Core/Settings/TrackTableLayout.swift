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
        try rejectUnknownKeys(decoder, CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
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
        var seen: Set<TrackColumn> = []
        for (index, layout) in columns.enumerated() {
            if !seen.insert(layout.column).inserted {
                return "columns[\(index)]: \(layout.column.rawValue) is listed twice"
            }
            if !Self.widthRange.contains(layout.width) {
                return "columns[\(index)]: width \(layout.width) is outside"
                    + " \(Self.widthRange.lowerBound)...\(Self.widthRange.upperBound)"
            }
        }
        return nil
    }
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
        try rejectUnknownKeys(decoder, CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        column = try container.decode(TrackColumn.self, forKey: .column)
        width = try container.decode(Double.self, forKey: .width)
    }
}
