/// What importing a playlist file did, for the status bar and the Problems window.
public struct PlaylistImport: Equatable, Sendable {
    public var playlistID: Int64
    public var name: String
    /// The playlist file's path.
    public var source: String
    public var added: Int
    /// Entries the index holds no track for, in the file's order.
    public var missing: [String]
    /// Entries naming a track already added, which a playlist holds once (ADR 0018).
    public var repeated: Int
    public var file: PlaylistFile
}
