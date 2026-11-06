import Settings

/// What a click in Listening Stats narrows the track table under it to, within the period
/// shown (ADR 0105): the tracks of one row of a list, or those played in one bar's span.
public struct StatsFilter: Hashable, Sendable {
    public enum Item: Hashable, Sendable {
        /// An artist, album, genre or track (a path ID), by the ID the list's row has.
        case entry(StatsReport.List, Int64)
        case span(PlaySpan)
    }

    public var item: Item
    /// What the panel calls it: the row's name, or what the bar covers.
    public var title: String

    public init(_ item: Item, title: String) {
        self.item = item
        self.title = title
    }
}
