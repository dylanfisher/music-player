/// The sort chosen in a source that opens in a sort of its own, such as a manual playlist or
/// History, kept with that source: the table's own sort is the track table layout's.
public struct SourceSort: SettingValue {
    public var source: BrowserSource
    public var column: TrackColumn
    public var ascending: Bool

    public init(source: BrowserSource, column: TrackColumn, ascending: Bool) {
        self.source = source
        self.column = column
        self.ascending = ascending
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case source, column, ascending
    }

    public init(from decoder: any Decoder) throws {
        let container = try strictContainer(decoder, CodingKeys.self)
        source = try container.decode(BrowserSource.self, forKey: .source)
        column = try container.decode(TrackColumn.self, forKey: .column)
        ascending = try container.decode(Bool.self, forKey: .ascending)
    }

    public static var typeName: String { "a source's sort (source, column, ascending)" }
    public static var kind: SettingKind { .windowState }

    public func problem() -> String? {
        column.isSortable ? nil : "column: \(column.rawValue) can't be sorted by"
    }
}
