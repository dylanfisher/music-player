public enum LibraryError: Error, Equatable, CustomStringConvertible {
    /// A stored warning or failure kind this build doesn't know, from a database another build
    /// wrote.
    case unknownKind(String)
    /// A scan of a folder into the app's own index that the app doesn't watch, whose files it
    /// would remove at its next launch.
    case notWatched(String)

    public var description: String {
        switch self {
        case .unknownKind(let name): "the library database holds an unknown kind \"\(name)\""
        case .notWatched(let path):
            "\(path) isn't a watched folder; add it in settings,"
                + " or pass --db <file> to scan into a separate index"
        }
    }
}
