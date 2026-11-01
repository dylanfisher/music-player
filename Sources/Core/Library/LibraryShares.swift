import Foundation
import Log
import Settings

private let logger = moduleLogger()

extension LibraryIndex {
    /// `folders` where they are now, in order (ADR 0028). A folder stored by path is as
    /// configured. A folder on one of `shares` is under its mount point, and when that moved,
    /// the paths under the old one are rewritten first. Any other keeps the root its paths
    /// have, so its scans report it offline.
    public func locate(_ folders: [WatchedFolder], among shares: [MountedShare]) throws
        -> [WatchedFolder]
    {
        try folders.map { folder in
            guard let share = folder.share else { return folder }
            switch ShareLookup(try shareURL(share), among: shares) {
            case .mounted(let mountPoint):
                let root = canonicalPath(
                    folder.path.isEmpty ? mountPoint : mountPoint + "/" + folder.path)
                do {
                    try relocate(share: share, path: folder.path, to: root)
                    return folder.located(at: root)
                } catch let error as LibraryError {
                    // Only this folder's paths are wrong, so the others are still found.
                    logger.error("\(error)")
                }
            case .unmounted:
                logger.error("\(share) isn't mounted, so its folder \(folder.path) is offline")
            case .ambiguous(let mountPoints):
                logger.error(
                    "\(share) could be the share at any of \(mountPoints), so its folder \(folder.path) is offline until one is ejected"
                )
            }
            return folder.located(at: try lastRoot(of: folder))
        }
    }

    /// `folders` where their paths were last, without looking at what's mounted: for the window
    /// at launch, before the watcher locates them.
    public func lastKnownFolders(_ folders: [WatchedFolder]) throws -> [WatchedFolder] {
        try folders.map { folder in
            folder.share == nil ? folder : folder.located(at: try lastRoot(of: folder))
        }
    }

    /// Where the share folder `folder`'s paths were last. One never located has none, and its
    /// URL stands in, which no scan finds as a directory.
    private func lastRoot(of folder: WatchedFolder) throws -> String {
        guard let share = folder.share else {
            preconditionFailure("\(folder.path) isn't on a share")
        }
        return try storedRoot(share: share, path: folder.path)
            ?? (folder.path.isEmpty ? share : share + "/" + folder.path)
    }

    private func storedRoot(share: String, path: String) throws -> String? {
        try statement(
            "SELECT root FROM \(shareRootsTable) WHERE share = ? AND inner_path = ?"
        ).map(share, path) { try $0.text(0) }.first
    }

    /// Records that the folder `path` in `share` is at `root`, rewriting every path under the
    /// root it had before, in one transaction, so IDs, Date Added and stats stay.
    func relocate(share: String, path: String, to root: String) throws {
        try database.transaction {
            let old = try storedRoot(share: share, path: path)
            guard old != root else { return }
            if let old { try rewritePaths(under: old, to: root) }
            try statement(
                "INSERT OR REPLACE INTO \(shareRootsTable) (share, inner_path, root) VALUES (?, ?, ?)"
            ).run(share, path, root)
            logger.notice("\(share) folder \(path) is at \(root), no longer \(old ?? "unknown")")
        }
    }

    /// Moves every files and paths row under `old` to the same place under `new`. A file the
    /// index already holds under `new` is dropped for the next scan to read again. Where a path
    /// is under both, the one without stats gives way; when both have stats, the old one stays
    /// where it was, for Lost Stats. Call inside a transaction.
    func rewritePaths(under old: String, to new: String) throws {
        guard !isPath(new, under: old), !isPath(old, under: new) else {
            throw LibraryError.nestedRoots(old, new)
        }
        // files.path is spelled as canonicalPath spells roots; paths.path is in NFC.
        let (oldFile, newFile) = (stem(old), stem(new))
        let (oldPath, newPath) = (
            oldFile.precomposedStringWithCanonicalMapping,
            newFile.precomposedStringWithCanonicalMapping
        )
        let newFiles = exactPathRange(under: newFile)
        try statement(
            "DELETE FROM track_search WHERE rowid IN (SELECT id FROM files WHERE path >= ? AND path < ?)"
        ).run(newFiles.lowerBound, newFiles.upperBound)
        try statement("DELETE FROM files WHERE path >= ? AND path < ?").run(
            newFiles.lowerBound, newFiles.upperBound)

        let oldPaths = exactPathRange(under: oldPath)
        let taken = try statement(
            """
            SELECT o.id, n.id, \(hasStats("o.id")), \(hasStats("n.id")) FROM paths o
            JOIN paths n ON n.path = ? || substr(o.path, ?)
            WHERE o.path >= ? AND o.path < ?
            """
        ).map(
            newPath, oldPath.unicodeScalars.count + 1, oldPaths.lowerBound, oldPaths.upperBound
        ) { row in
            (
                old: try row.int64(0), new: try row.int64(1), oldHasStats: try row.int(2) == 1,
                newHasStats: try row.int(3) == 1
            )
        }
        var kept: [Int64] = []
        for row in taken {
            if !row.newHasStats {
                try deletePath(row.new)
                continue
            }
            kept.append(row.old)
            try deleteFile(row.old)
            if !row.oldHasStats { try deletePath(row.old) }
        }
        let keptList = kept.map(String.init).joined(separator: ", ")
        try statement(
            """
            UPDATE paths SET path = ? || substr(path, ?)
            WHERE path >= ? AND path < ? AND id NOT IN (\(keptList))
            """
        ).run(newPath, oldPath.unicodeScalars.count + 1, oldPaths.lowerBound, oldPaths.upperBound)
        let oldFiles = exactPathRange(under: oldFile)
        try statement(
            """
            UPDATE files SET path = ? || substr(path, ?), name_offset = name_offset + ?
            WHERE path >= ? AND path < ?
            """
        ).run(
            newFile, oldFile.unicodeScalars.count + 1,
            newFile.unicodeScalars.count - oldFile.unicodeScalars.count, oldFiles.lowerBound,
            oldFiles.upperBound)
    }
}

extension WatchedFolder {
    /// This folder with `root` as its path, as the scanner and the window take it.
    func located(at root: String) -> WatchedFolder {
        WatchedFolder(
            path: root, kind: kind, include: include, exclude: exclude,
            pollIntervalMinutes: pollIntervalMinutes)
    }
}

/// A configured share's URL, which the settings checked.
private func shareURL(_ share: String) throws -> ShareURL {
    guard let url = ShareURL(share) else {
        preconditionFailure("\(share) passed the settings check")
    }
    return url
}

/// How to store a folder the user picked at `path`: by its share and the path inside it when
/// it's on one of `shares` (ADR 0028), else by its path. `isLocal` picks how it's watched.
public func folderToWatch(_ path: String, isLocal: Bool, among shares: [MountedShare])
    -> WatchedFolder
{
    guard !isLocal,
        let share = shares.filter({ path == $0.mountPoint || isPath(path, under: $0.mountPoint) })
            .max(by: { $0.mountPoint.count < $1.mountPoint.count }),
        ShareURL(share.url) != nil
    else { return WatchedFolder(path: path, kind: isLocal ? .local : .network) }
    let inner = String(canonicalPath(path).dropFirst(stem(share.mountPoint).count + 1))
    return WatchedFolder(
        path: inner.precomposedStringWithCanonicalMapping, share: share.url, kind: .network)
}

extension LibraryIndex {
    /// `folders` without the one the window lists at `path`.
    public func folders(_ folders: [WatchedFolder], without path: String) throws
        -> [WatchedFolder]
    {
        zip(folders, try lastKnownFolders(folders)).filter { $0.1.path != path }.map(\.0)
    }
}
