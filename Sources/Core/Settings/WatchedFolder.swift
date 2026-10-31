/// A folder the library scans, and how it learns about changes in it.
public struct WatchedFolder: SettingValue {
    public enum Kind: String, Codable, Sendable {
        /// Watched with FSEvents.
        case local
        /// Rescanned every `pollIntervalMinutes`, because FSEvents doesn't report changes on SMB
        /// volumes.
        case network
    }

    public static let defaultPollIntervalMinutes = 15
    public static let pollIntervalRangeMinutes = 1...1440

    /// The root, as an absolute path.
    public var path: String
    public var kind: Kind
    /// Glob patterns relative to the root. An empty list includes everything.
    public var include: [String]
    /// Glob patterns relative to the root, applied after `include`.
    public var exclude: [String]
    /// Only network roots use it.
    public var pollIntervalMinutes: Int

    public init(
        path: String, kind: Kind, include: [String] = [], exclude: [String] = [],
        pollIntervalMinutes: Int = defaultPollIntervalMinutes
    ) {
        self.path = path
        self.kind = kind
        self.include = include
        self.exclude = exclude
        self.pollIntervalMinutes = pollIntervalMinutes
    }

    public static var typeName: String {
        "a watched folder (path, kind, include, exclude, pollIntervalMinutes)"
    }
    public static var kind: SettingKind { .watchedFolder }

    public func problem() -> String? {
        let range = Self.pollIntervalRangeMinutes
        if !path.hasPrefix("/") { return "path \"\(path)\" isn't absolute" }
        if !range.contains(pollIntervalMinutes) {
            return "pollIntervalMinutes \(pollIntervalMinutes) is outside"
                + " \(range.lowerBound)...\(range.upperBound)"
        }
        return nil
    }
}
