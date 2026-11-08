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
        try rejectUnknownKeys(decoder, FolderSettingKeys.self)
        let container = try decoder.container(keyedBy: FolderSettingKeys.self)
        self.init(
            path: try container.decode(String.self, forKey: .path),
            share: try container.decodeIfPresent(String.self, forKey: .share))
    }

    public func problem() -> String? { folderLocationProblem(path: path, share: share) }
}
