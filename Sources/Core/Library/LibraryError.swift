public enum LibraryError: Error, Equatable, CustomStringConvertible {
    /// A stored warning or failure kind this build doesn't know, from a database another build
    /// wrote.
    case unknownKind(String)

    public var description: String {
        switch self {
        case .unknownKind(let name): "the library database holds an unknown kind \"\(name)\""
        }
    }
}
