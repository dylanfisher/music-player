import StrictKeys

/// A folder setting stored as a path, or on a network share as the share's URL and the path
/// inside it, found wherever the share is mounted, as a watched folder is (ADR 0028). Its JSON
/// is `{"path": …, "share": …}`, with `share` left out for a folder stored by path.
public protocol FolderSetting: SettingValue {
    /// An absolute path; for a folder on a share, its path inside the share, with no leading
    /// slash, and empty for the share itself.
    var path: String { get }
    var share: String? { get }
    init(path: String, share: String?)
}

private enum FolderSettingKeys: String, CodingKey, CaseIterable {
    case path, share
}

extension FolderSetting {
    public init(from decoder: any Decoder) throws {
        let container = try strictContainer(decoder, FolderSettingKeys.self)
        self.init(
            path: try container.decode(String.self, forKey: .path),
            share: try container.decodeIfPresent(String.self, forKey: .share))
    }

    public func problem() -> String? { folderLocationProblem(path: path, share: share) }
}

/// What sets one folder setting apart from another: its name in errors and its kind.
public protocol FolderRole: Sendable {
    /// Completes "expected …" in an error.
    static var typeName: String { get }
    static var kind: SettingKind { get }
}

/// A folder setting's value. The dumps, staging and sync folders differ only in their role, and
/// what one of them does with its folder is an extension on its own `SettingFolder`.
public struct SettingFolder<Role: FolderRole>: FolderSetting {
    public var path: String
    public var share: String?

    public init(path: String, share: String? = nil) {
        self.path = path
        self.share = share
    }

    public static var typeName: String { Role.typeName }
    public static var kind: SettingKind { Role.kind }
}
