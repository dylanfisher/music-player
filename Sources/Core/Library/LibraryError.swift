public enum LibraryError: Error, Equatable, CustomStringConvertible {
    /// A stored warning or failure kind this build doesn't know, from a database another build
    /// wrote.
    case unknownKind(String)
    /// A scan of a folder into the app's own index that the app doesn't watch, whose files it
    /// would remove at its next launch.
    case notWatched(String)
    /// A playlist ID the database doesn't hold, such as one deleted since it was listed.
    case unknownPlaylist(Int64)
    /// A track edit asked of a smart playlist, whose tracks come from its rules.
    case smartPlaylist(String)
    /// A rule the editor let through that can't be compiled.
    case invalidRule(String)
    /// A smart playlist whose stored rules this build can't read.
    case unreadableRules(playlist: String, detail: String)
    /// A track query asked of the timeline, which lists plays.
    case playsNotTracks

    public var description: String {
        switch self {
        case .unknownKind(let name): "the library database holds an unknown kind \"\(name)\""
        case .notWatched(let path):
            "\(path) isn't a watched folder; add it in settings,"
                + " or pass --db <file> to scan into a separate index"
        case .unknownPlaylist(let id): "the library has no playlist \(id)"
        case .smartPlaylist(let name):
            "\"\(name)\" is a smart playlist; its rules choose its tracks"
        case .invalidRule(let problem): "a smart playlist rule is invalid: \(problem)"
        case .unreadableRules(let name, let detail):
            "the rules of \"\(name)\" can't be read: \(detail)"
        case .playsNotTracks: "the timeline lists plays, not tracks"
        }
    }
}
