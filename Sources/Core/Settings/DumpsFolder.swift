import Foundation

/// The folder of the Discogs dumps the catalog is imported from (ADR 0130): a path, or on a
/// network share the share's URL and the path inside it, found wherever the share is mounted,
/// as a watched folder is (ADR 0028). The app only reads it.
public struct DumpsFolder: FolderSetting {
    public var path: String
    public var share: String?

    public init(path: String, share: String? = nil) {
        self.path = path
        self.share = share
    }

    public static var typeName: String { "a dumps folder (path, optional share)" }
    public static var kind: SettingKind { .dumpsFolder }
}
