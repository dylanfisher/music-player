/// One column of the browser: what it groups by, and the entry selected in it by name, since
/// IDs change when the index is rebuilt. A nil selection is All.
public struct BrowserColumn: SettingValue {
    public var grouping: BrowserGrouping
    public var selection: String?

    /// The browser has three columns, as Swinsian's does.
    public static let count = 3
    /// Genres, Artists and Albums, nothing selected.
    public static let defaults = [BrowserGrouping.genres, .artists, .albums].map {
        BrowserColumn(grouping: $0, selection: nil)
    }

    public init(grouping: BrowserGrouping, selection: String?) {
        self.grouping = grouping
        self.selection = selection
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case grouping, selection
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(decoder, CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        grouping = try container.decode(BrowserGrouping.self, forKey: .grouping)
        selection = try container.decode(String?.self, forKey: .selection)
    }

    public static var typeName: String { "a browser column (grouping, selection)" }
    public static var kind: SettingKind { .windowState }
}
