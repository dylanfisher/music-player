/// How the user left each of the Discogs tagger's sheets (ADR 0136): its size and its table's
/// columns and sort, by kind of sheet; and the window's album list, its pane's width and its
/// columns and sort (ADR 0176). Nil for one never changed, which opens at its own.
public struct TaggerSheetLayouts: SettingValue {
    /// One sheet's size in points and its table's columns, by the tagger's column names.
    public struct Layout: Codable, Equatable, Sendable {
        public var width: Double
        public var height: Double
        public var table: TableLayout

        public init(width: Double, height: Double, table: TableLayout) {
            self.width = width
            self.height = height
            self.table = table
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case width, height, table
        }

        public init(from decoder: any Decoder) throws {
            try rejectUnknownKeys(decoder, CodingKeys.self)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            width = try container.decode(Double.self, forKey: .width)
            height = try container.decode(Double.self, forKey: .height)
            table = try container.decode(TableLayout.self, forKey: .table)
        }
    }

    /// The album list beside the tracklists: the width its pane was dragged to, in points, and
    /// its table's columns.
    public struct AlbumList: Codable, Equatable, Sendable {
        public var paneWidth: Double
        public var table: TableLayout

        public init(paneWidth: Double, table: TableLayout) {
            self.paneWidth = paneWidth
            self.table = table
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case paneWidth, table
        }

        public init(from decoder: any Decoder) throws {
            try rejectUnknownKeys(decoder, CodingKeys.self)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            paneWidth = try container.decode(Double.self, forKey: .paneWidth)
            table = try container.decode(TableLayout.self, forKey: .table)
        }
    }

    public var otherReleases: Layout?
    public var viewRelease: Layout?
    public var viewChanges: Layout?
    public var fieldMapping: Layout?
    public var albumList: AlbumList?

    public init(
        otherReleases: Layout? = nil, viewRelease: Layout? = nil, viewChanges: Layout? = nil,
        fieldMapping: Layout? = nil, albumList: AlbumList? = nil
    ) {
        self.otherReleases = otherReleases
        self.viewRelease = viewRelease
        self.viewChanges = viewChanges
        self.fieldMapping = fieldMapping
        self.albumList = albumList
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case otherReleases, viewRelease, viewChanges, fieldMapping, albumList
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(decoder, CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        otherReleases = try container.decodeIfPresent(Layout.self, forKey: .otherReleases)
        viewRelease = try container.decodeIfPresent(Layout.self, forKey: .viewRelease)
        viewChanges = try container.decodeIfPresent(Layout.self, forKey: .viewChanges)
        fieldMapping = try container.decodeIfPresent(Layout.self, forKey: .fieldMapping)
        albumList = try container.decodeIfPresent(AlbumList.self, forKey: .albumList)
    }

    public static var typeName: String {
        "the tagger's layouts (otherReleases, viewRelease, viewChanges, fieldMapping, albumList)"
    }
    public static var kind: SettingKind { .windowState }

    public func problem() -> String? {
        let layouts = [otherReleases, viewRelease, viewChanges, fieldMapping].compactMap { $0 }
        for layout in layouts {
            if !(layout.width > 0 && layout.height > 0) { return "a sheet's size isn't positive" }
        }
        if let albumList, !(albumList.paneWidth > 0) {
            return "the album list's width isn't positive"
        }
        let tables = layouts.map(\.table) + [albumList?.table].compactMap { $0 }
        return tables.lazy.compactMap { $0.problem() }.first
    }
}
