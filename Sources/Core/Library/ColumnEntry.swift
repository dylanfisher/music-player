/// An entry of a browser column: what it stands for, and its text.
public struct ColumnEntry: Equatable, Sendable {
    public var value: BrowserValue
    /// What the column shows.
    public var name: String
    /// What the window saves to find it again after a relaunch, since IDs change when the index
    /// is rebuilt: the genre's or artist's name, the album's title, or the text.
    public var savedName: String
}
