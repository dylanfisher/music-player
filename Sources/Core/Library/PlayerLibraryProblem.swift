/// Something wrong with one row, key or value of another player's library. It's left out and
/// the rest is read.
public struct PlayerLibraryProblem: Equatable, Sendable, CustomStringConvertible {
    public enum Kind: Equatable, Sendable {
        /// A column or key holding another type than the one read, such as text for a count.
        case wrongType(String, expected: String)
        /// A date before 1970 or in the future, a negative count, a rating past 5 stars.
        case outOfRange(String, String)
        /// No path, or a `Location` that isn't a `file:` URL of this Mac.
        case noPath
        case notAbsolute
        case badFileURL
        case tooLong(Int)
        case holdsNUL
        /// A playlist entry naming a track ID the library doesn't hold.
        case unknownTrack(Int64)
        /// Past a cap; this and the rest of its kind weren't read.
        case tooMany(Cap)
    }

    /// The row or key, such as "track 12" or "playlist “Mix”".
    public var item: String
    public var kind: Kind

    /// What a library holds at most of each (ADR 0033).
    public enum Cap: String, Sendable, CustomStringConvertible {
        case tracks, playlists, entries

        var limit: Int {
            switch self {
            case .tracks: PlayerLibrary.maximumTracks
            case .playlists: PlayerLibrary.maximumPlaylists
            case .entries: PlayerLibrary.maximumEntries
            }
        }

        public var description: String { rawValue }
    }

    static func track(_ id: some CustomStringConvertible) -> String { "track \(id)" }
    static func playlist(_ number: Int64) -> String { "playlist \(number)" }
    static func playlist(named name: String) -> String { "playlist “\(name)”" }

    init(_ item: String, _ kind: Kind) {
        self.item = item
        self.kind = kind
    }

    public var description: String {
        let what =
            switch kind {
            case .wrongType(let field, let expected): "\(field) isn't \(expected)"
            case .outOfRange(let field, let value): "\(field) \(value) is out of range"
            case .noPath: "has no file path"
            case .notAbsolute: "its path isn't absolute"
            case .badFileURL: "its location isn't a file: URL on this Mac"
            case .tooLong(let bytes): "over \(bytes) bytes"
            case .holdsNUL: "holds a NUL"
            case .unknownTrack(let id): "names track \(id), which the library doesn't hold"
            case .tooMany(let cap): "past \(cap.limit) \(cap); the rest weren't read"
            }
        return "\(item): \(what)"
    }
}
