/// A playlist as the sidebar lists it.
public struct Playlist: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Tracks the user added, in the order they arranged.
        case manual
        case smart(SmartRules)
        /// Smart, with stored rules this build can't read. Listed, so it can be deleted, but
        /// showing it fails with the reason.
        case unreadable(String)
    }

    /// Kept by an index rebuild, since playlists live with the stats (ADR 0018).
    public var id: Int64
    public var name: String
    public var kind: Kind

    public init(id: Int64, name: String, kind: Kind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    public var isManual: Bool { kind == .manual }
}
