/// A command's name in the registry, the config file's `"shortcuts"` and the remote API:
/// `selection.tenRowsDown`. It never changes once shipped, since stored shortcuts refer to it.
public struct CommandID: RawRepresentable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public static func < (a: CommandID, b: CommandID) -> Bool { a.rawValue < b.rawValue }
}
