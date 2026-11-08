import Foundation

/// The folder music-recommender puts downloaded albums in for review (ADR 0144): a path, or on
/// a network share the share's URL and the path inside it, found wherever the share is mounted,
/// as a watched folder is (ADR 0028). The service names each album's folder relative to it.
public struct StagingFolder: FolderSetting {
    public var path: String
    public var share: String?

    public init(path: String, share: String? = nil) {
        self.path = path
        self.share = share
    }

    public static var typeName: String { "a staging folder (path, optional share)" }
    public static var kind: SettingKind { .stagingFolder }

    /// The folder of `folders` it's in or that's in it, which the app would scan or write
    /// while the service deletes there; nil when they're apart. One stored by share and one by
    /// path can't be compared until they're found.
    func overlap(_ folders: [(path: String, share: String?)]) -> String? {
        folders.first {
            isFolder(path, share: share, inOrAt: $0.path, share: $0.share)
                || isFolder($0.path, share: $0.share, inOrAt: path, share: share)
        }.map(\.path)
    }
}
