/// The play timeline's columns: Played, always first, with its width, and the track columns
/// after it, left to right, with theirs.
public struct TimelineLayout: SettingValue {
    public var playedWidth: Double
    public var columns: [ColumnLayout]

    public init(playedWidth: Double, columns: [ColumnLayout]) {
        self.playedWidth = playedWidth
        self.columns = columns
    }

    /// Whether the timeline can show `column`. Album Art groups rows by album, Order is a
    /// playlist's, and Now Playing marks the track table's playing row, none of which a play
    /// has.
    public static func shows(_ column: TrackColumn) -> Bool {
        ![.art, .playlistOrder, .nowPlaying].contains(column)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case playedWidth, columns
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(decoder, CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        playedWidth = try container.decode(Double.self, forKey: .playedWidth)
        columns = try container.decode([ColumnLayout].self, forKey: .columns)
    }

    public static var typeName: String { "a timeline layout (playedWidth, columns)" }
    public static var kind: SettingKind { .windowState }

    public func problem() -> String? {
        if let problem = widthProblem(playedWidth) { return "playedWidth: \(problem)" }
        if let index = columns.firstIndex(where: { !Self.shows($0.column) }) {
            return "columns[\(index)]: the timeline can't show \(columns[index].column.rawValue)"
        }
        return columnsProblem(columns)
    }
}
