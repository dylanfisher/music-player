/// How the user left each of the Discogs tagger's sheets (ADR 0136): its size, its columns'
/// widths and its sort, by kind of sheet. Nil for a sheet never resized, which opens at its
/// own size.
public struct TaggerSheetLayouts: SettingValue {
    /// One sheet's size in points, its columns' widths by the tagger's column names, and the
    /// column it sorts by. A column the sheet no longer has is ignored when it opens.
    public struct Layout: Codable, Equatable, Sendable {
        public var width: Double
        public var height: Double
        public var columns: [String: Double]
        /// Nil for a sheet that doesn't sort, or wasn't sorted.
        public var sortColumn: String?
        public var sortAscending: Bool

        public init(
            width: Double, height: Double, columns: [String: Double], sortColumn: String?,
            sortAscending: Bool
        ) {
            self.width = width
            self.height = height
            self.columns = columns
            self.sortColumn = sortColumn
            self.sortAscending = sortAscending
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case width, height, columns, sortColumn, sortAscending
        }

        public init(from decoder: any Decoder) throws {
            try rejectUnknownKeys(decoder, CodingKeys.self)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            width = try container.decode(Double.self, forKey: .width)
            height = try container.decode(Double.self, forKey: .height)
            columns = try container.decode([String: Double].self, forKey: .columns)
            sortColumn = try container.decodeIfPresent(String.self, forKey: .sortColumn)
            sortAscending = try container.decode(Bool.self, forKey: .sortAscending)
        }
    }

    public var otherReleases: Layout?
    public var viewRelease: Layout?
    public var viewChanges: Layout?
    public var fieldMapping: Layout?

    public init(
        otherReleases: Layout? = nil, viewRelease: Layout? = nil, viewChanges: Layout? = nil,
        fieldMapping: Layout? = nil
    ) {
        self.otherReleases = otherReleases
        self.viewRelease = viewRelease
        self.viewChanges = viewChanges
        self.fieldMapping = fieldMapping
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case otherReleases, viewRelease, viewChanges, fieldMapping
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(decoder, CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        otherReleases = try container.decodeIfPresent(Layout.self, forKey: .otherReleases)
        viewRelease = try container.decodeIfPresent(Layout.self, forKey: .viewRelease)
        viewChanges = try container.decodeIfPresent(Layout.self, forKey: .viewChanges)
        fieldMapping = try container.decodeIfPresent(Layout.self, forKey: .fieldMapping)
    }

    public static var typeName: String {
        "the tagger sheets' layouts (otherReleases, viewRelease, viewChanges, fieldMapping)"
    }
    public static var kind: SettingKind { .windowState }

    public func problem() -> String? {
        let layouts = [otherReleases, viewRelease, viewChanges, fieldMapping].compactMap { $0 }
        for layout in layouts {
            if !(layout.width > 0 && layout.height > 0) { return "a sheet's size isn't positive" }
            if layout.columns.values.contains(where: { !($0 > 0) }) {
                return "a column's width isn't positive"
            }
        }
        return nil
    }
}
