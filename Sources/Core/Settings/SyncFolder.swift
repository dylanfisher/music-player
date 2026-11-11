import Foundation

/// The folder machines share their logs through (ADR 0038): a path, or on a network share the
/// share's URL and the path inside it, found wherever the share is mounted, as a watched folder
/// is (ADR 0028).
public typealias SyncFolder = SettingFolder<SyncFolderRole>

public enum SyncFolderRole: FolderRole {
    public static var typeName: String { "a sync folder (path, optional share)" }
    public static var kind: SettingKind { .syncFolder }
}

extension SettingFolder where Role == SyncFolderRole {
    /// Names the folder in `sync_state`, so a log pushed to one folder starts again in another.
    public var identity: String { share.map { "\($0) \(path)" } ?? path }

    /// Whether this folder is `folder` or inside it, when both are stored the same way. One
    /// stored by share and one by path can't be compared until they're found, so the sync
    /// checks the found paths too.
    func isInside(_ folder: WatchedFolder) -> Bool {
        isFolder(path, share: share, inOrAt: folder.path, share: folder.share)
    }
}

/// Whether the folder at `path`, in `share` when it has one, is the folder at `folderPath` or
/// inside it, when both are stored the same way; false when one is stored by share and the
/// other by path.
func isFolder(_ path: String, share: String?, inOrAt folderPath: String, share folderShare: String?)
    -> Bool
{
    switch (share.flatMap(ShareURL.init), folderShare.flatMap(ShareURL.init)) {
    case (nil, nil):
        return isPath(standardized(path), inOrAt: standardized(folderPath))
    case (let mine?, let theirs?):
        // Hosts differ between Macs, so a share with the same name is taken to be the same.
        return mine.hasSameName(as: theirs)
            && (folderPath.isEmpty
                || isPath(
                    path.precomposedStringWithCanonicalMapping,
                    inOrAt: folderPath.precomposedStringWithCanonicalMapping))
    default:
        return false
    }
}

/// `path` in NFC with `.`, `..` and repeated slashes resolved, to compare with another.
public func standardized(_ path: String) -> String {
    (path.precomposedStringWithCanonicalMapping as NSString).standardizingPath
}

/// Whether `path` is `folder` or under it, comparing whole components.
public func isPath(_ path: String, inOrAt folder: String) -> Bool {
    let trimmed = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
    return path == trimmed || path.hasPrefix(trimmed + "/")
}
