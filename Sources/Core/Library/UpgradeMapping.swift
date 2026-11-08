/// One of an upgrade's old files, found in the index by its path on the share (ADR 0147).
package struct UpgradeOldFile: Equatable, Sendable {
    /// As the job lists it, relative to the share.
    package var sharePath: String
    package var path: String
    /// Its track's position in the release, as the matcher placed it; nil when it fits none.
    package var position: String?
    /// Plays, a rating, a love or a playlist entry, which a delete without a new file for it
    /// would lose.
    package var hasStats: Bool
}

/// How an upgrade's old files map to its new ones through the release's track positions: each
/// pair's stats move from the old file to the new, and an old file with no counterpart is
/// deleted with what it has, once the owner ticks it.
package struct UpgradeMapping: Equatable, Sendable {
    struct Pair: Equatable, Sendable {
        /// The old file's path relative to the share.
        var old: String
        /// The new file's name in the job's staged folder.
        var new: String
    }

    var pairs: [Pair]
    /// The old files with no new file at their position, in the job's order.
    package var unmatched: [UpgradeOldFile]

    /// Pairs each of `old` with the new file of `new` at its position. A position two old files
    /// share goes to the first; the other is unmatched.
    package init(old: [UpgradeOldFile], new: [(name: String, position: String?)]) {
        // The service names each position once (`ReleaseSnapshot.positions`).
        var byPosition: [String: String] = [:]
        for file in new {
            if let position = file.position { byPosition[position] = file.name }
        }
        pairs = []
        unmatched = []
        for file in old {
            if let position = file.position, let name = byPosition.removeValue(forKey: position) {
                pairs.append(Pair(old: file.sharePath, new: name))
            } else {
                unmatched.append(file)
            }
        }
    }
}

/// Why an upgrade's old files can't be replaced.
package enum UpgradeRefusal: Error, Equatable, CustomStringConvertible {
    /// The job lists a file the index doesn't have.
    case notInLibrary(String)
    /// The file no longer carries the job's release id, so it may not be the album's.
    case otherRelease(String, found: String?, expected: Int)

    package var description: String {
        switch self {
        case .notInLibrary(let path): "\(path) isn't in the library"
        case .otherRelease(let path, let found, let expected):
            "\(path) is tagged with " + (found.map { "release \($0)" } ?? "no release")
                + ", not \(expected)"
        }
    }
}

extension LibraryIndex {
    /// The upgrade's old files `sharePaths`, relative to the share mounted at `shareRoot`, as
    /// the index has them, with no position yet. Each must be a track that still carries
    /// `release`: only the album's own files are ever passed to the Trash.
    package func upgradeOldFiles(_ sharePaths: [String], release: Int, shareRoot: String) throws
        -> [UpgradeOldFile]
    {
        let lookup = try statement(
            """
            SELECT f.id, t.discogs_release_id FROM files f JOIN tracks t ON t.file_id = f.id
            WHERE f.path = ?
            """)
        return try sharePaths.map { sharePath in
            let path = stem(shareRoot) + "/" + sharePath
            guard
                let found = try lookup.map(path, row: { (try $0.int64(0), $0.optionalText(1)) })
                    .first
            else { throw UpgradeRefusal.notInLibrary(path) }
            guard found.1 == String(release) else {
                throw UpgradeRefusal.otherRelease(path, found: found.1, expected: release)
            }
            return UpgradeOldFile(
                sharePath: sharePath, path: path, position: nil,
                hasStats: try pathHasStats(found.0))
        }
    }
}
