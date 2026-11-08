import Foundation

/// The folder machines share their logs through (ADR 0038): a path, or on a network share the
/// share's URL and the path inside it, found wherever the share is mounted, as a watched folder
/// is (ADR 0028).
public struct SyncFolder: SettingValue {
    /// An absolute path; for a folder on a share, its path inside the share, with no leading
    /// slash, and empty for the share itself.
    public var path: String
    public var share: String?

    public init(path: String, share: String? = nil) {
        self.path = path
        self.share = share
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case path, share
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(decoder, CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        share = try container.decodeIfPresent(String.self, forKey: .share)
    }

    public static var typeName: String { "a sync folder (path, optional share)" }
    public static var kind: SettingKind { .syncFolder }

    public func problem() -> String? { folderLocationProblem(path: path, share: share) }

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
