import Foundation

/// A folder the library scans, and how it learns about changes in it.
public struct WatchedFolder: SettingValue {
    public enum Kind: String, Codable, Sendable {
        /// Watched with FSEvents.
        case local
        /// Rescanned every `pollIntervalMinutes`, because FSEvents doesn't report changes on SMB
        /// volumes.
        case network
    }

    /// Folders that hold the system or every user's files, never only music.
    static let refusedRoots: Set<String> = [
        "/", "/Applications", "/Library", "/Network", "/System", "/Users", "/Volumes", "/bin",
        "/cores", "/dev", "/etc", "/opt", "/private", "/sbin", "/tmp", "/usr", "/var",
    ]

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

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case path, kind, include, exclude, pollIntervalMinutes
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(decoder, CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        kind = try container.decode(Kind.self, forKey: .kind)
        include = try container.decode([String].self, forKey: .include)
        exclude = try container.decode([String].self, forKey: .exclude)
        pollIntervalMinutes = try container.decode(Int.self, forKey: .pollIntervalMinutes)
    }

    public static var typeName: String {
        "a watched folder (path, kind, include, exclude, pollIntervalMinutes)"
    }
    public static var kind: SettingKind { .watchedFolder }

    public func problem() -> String? {
        let range = Self.pollIntervalRangeMinutes
        if !path.hasPrefix("/") { return "path \"\(path)\" isn't absolute" }
        let standard = (path as NSString).standardizingPath
        if Self.refusedRoots.contains(standard) || standard == NSHomeDirectory() {
            return "path \"\(path)\" is a system folder or the home folder, not a music folder;"
                + " watching it would scan, and tag-edit, everything under it"
        }
        if !range.contains(pollIntervalMinutes) {
            return "pollIntervalMinutes \(pollIntervalMinutes) is outside"
                + " \(range.lowerBound)...\(range.upperBound)"
        }
        return nil
    }
}
