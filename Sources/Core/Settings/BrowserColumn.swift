/// One column of the browser: what it groups by, and the entry selected in it by name, since
/// IDs change when the index is rebuilt. A nil selection is All.
public struct BrowserColumn: SettingValue {
    public var grouping: BrowserGrouping
    public var selection: String?

    /// How many columns the browser may have. Three by default, as Swinsian's; six at most,
    /// which on a 13-inch screen beside the sidebar still leaves each about 150 points
    /// (ADR 0161).
    public static let counts = 1...6
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

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(grouping, forKey: .grouping)
        // Null, not left out, since the key is required.
        try container.encode(selection, forKey: .selection)
    }

    public static var typeName: String { "a browser column (grouping, selection)" }
    public static var kind: SettingKind { .windowState }

    /// The columns to load: `saved`, the state file's, grouped as `groupings` says when the
    /// config file names them. A saved selection stays only in a column that still groups by
    /// what it was made in, since a name means nothing in another grouping (ADR 0106). The
    /// config file's count wins: columns past the state file's start at All.
    public static func restored(_ saved: [BrowserColumn], groupings: [BrowserGrouping]?)
        -> [BrowserColumn]
    {
        guard let groupings else { return saved }
        return groupings.enumerated().map { index, grouping in
            let column = saved.indices.contains(index) ? saved[index] : nil
            return BrowserColumn(
                grouping: grouping,
                selection: column?.grouping == grouping ? column?.selection : nil)
        }
    }
}
