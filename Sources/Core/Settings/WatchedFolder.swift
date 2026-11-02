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

    public static let defaultPollIntervalMinutes = 60
    public static let pollIntervalRangeMinutes = 1...1440
    /// The config file's key for `pollIntervalMinutes`, which Settings edits in place.
    public static let pollIntervalMinutesKey = CodingKeys.pollIntervalMinutes.rawValue

    /// The root, as an absolute path; for a folder on a share, its path inside the share, with
    /// no leading slash, and empty for the share itself.
    public var path: String
    /// For a folder on a network share, the share's URL (`smb://nas/music`), so the folder is
    /// found wherever the share is mounted (ADR 0028). Nil for a folder stored by its path.
    public var share: String?
    public var kind: Kind
    /// Glob patterns relative to the root. An empty list includes everything.
    public var include: [String]
    /// Glob patterns relative to the root, applied after `include`.
    public var exclude: [String]
    /// Only network roots use it.
    public var pollIntervalMinutes: Int

    public init(
        path: String, share: String? = nil, kind: Kind, include: [String] = [],
        exclude: [String] = [], pollIntervalMinutes: Int = defaultPollIntervalMinutes
    ) {
        self.path = path
        self.share = share
        self.kind = kind
        self.include = include
        self.exclude = exclude
        self.pollIntervalMinutes = pollIntervalMinutes
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case path, share, kind, include, exclude, pollIntervalMinutes
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(decoder, CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        share = try container.decodeIfPresent(String.self, forKey: .share)
        kind = try container.decode(Kind.self, forKey: .kind)
        include = try container.decode([String].self, forKey: .include)
        exclude = try container.decode([String].self, forKey: .exclude)
        pollIntervalMinutes = try container.decode(Int.self, forKey: .pollIntervalMinutes)
    }

    public static var typeName: String {
        "a watched folder (path, optional share, kind, include, exclude, pollIntervalMinutes)"
    }
    public static var kind: SettingKind { .watchedFolder }

    public func problem() -> String? {
        let range = Self.pollIntervalRangeMinutes
        if let problem = folderLocationProblem(path: path, share: share) { return problem }
        if let share, kind != .network {
            return "a folder on share \"\(share)\" needs kind network"
        }
        let standard = (path as NSString).standardizingPath
        if share == nil, Self.refusedRoots.contains(standard) || standard == NSHomeDirectory() {
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

/// Why a folder stored as `path`, inside `share` when there is one, can't be found: a share
/// that isn't a URL, a path inside a share that starts with / or leaves it, or a path that
/// isn't absolute.
func folderLocationProblem(path: String, share: String?) -> String? {
    if let share {
        if ShareURL(share) == nil {
            return "share \"\(share)\" isn't a URL with a host and a share, such as"
                + " smb://nas/music"
        }
        if path.hasPrefix("/") {
            return "path \"\(path)\" is inside share \"\(share)\", so it can't start with /"
        }
        if path.split(separator: "/").contains("..") {
            return "path \"\(path)\" leaves share \"\(share)\""
        }
    } else if !path.hasPrefix("/") {
        return "path \"\(path)\" isn't absolute"
    }
    return nil
}
