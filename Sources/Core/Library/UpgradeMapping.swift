import Foundation

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
    /// The Discogs release id its track carried when it was found, nil for none, which it must
    /// still carry when it's passed to the Trash (ADR 0169).
    package var release: String?
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

extension UpgradeMapping {
    /// The old files of `old` whose new file goes to their own path, given where each new
    /// file goes by name, `destinations`: each is set aside before its new file moves in, and
    /// its stats stay with the path. Throws when a new file goes to an old file's path but
    /// isn't paired with it, since that old file's stats would go to the wrong track.
    package func replacedInPlace(_ old: [UpgradeOldFile], destinations: [String: String]) throws
        -> [UpgradeOldFile]
    {
        let key = { (path: String) in path.precomposedStringWithCanonicalMapping }
        let paired = Dictionary(
            pairs.compactMap { pair in destinations[pair.new].map { (pair.old, key($0)) } },
            uniquingKeysWith: { one, _ in one })
        let taken = Set(destinations.values.map(key))
        var inPlace: [UpgradeOldFile] = []
        var crossed: [String] = []
        for file in old where taken.contains(key(file.path)) {
            if paired[file.sharePath] == key(file.path) {
                inPlace.append(file)
            } else {
                crossed.append(file.path)
            }
        }
        guard crossed.isEmpty else { throw MoveRefusal.collisions(crossed) }
        return inPlace
    }
}

/// Why an upgrade's old files can't be replaced.
package enum UpgradeRefusal: Error, Equatable, CustomStringConvertible {
    /// The job lists a file the index doesn't have.
    case notInLibrary(String)
    /// The file no longer carries the release id it's held to, nil for none, so it may not
    /// be the album's.
    case otherRelease(String, found: String?, expected: String?)

    package var description: String {
        switch self {
        case .notInLibrary(let path): "\(path) isn't in the library"
        case .otherRelease(let path, let found, let expected):
            "\(path) is tagged with " + (found.map { "release \($0)" } ?? "no release")
                + (expected.map { ", not release \($0)" } ?? ", and had no release when approved")
        }
    }
}

extension LibraryIndex {
    /// The upgrade's old files `sharePaths`, relative to the share mounted at `shareRoot`, as
    /// the index has them, each with the release id its track carries and no position yet.
    package func upgradeOldFiles(_ sharePaths: [String], shareRoot: String) throws
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
            return UpgradeOldFile(
                sharePath: sharePath, path: path, position: nil,
                hasStats: try pathHasStats(found.0), release: found.1)
        }
    }

    /// As `upgradeOldFiles(_:shareRoot:)`, refusing any whose track no longer carries the
    /// release id it's held to: `held`'s for its share path, else `release`. Only the album's
    /// own files are ever passed to the Trash.
    package func upgradeOldFiles(
        _ sharePaths: [String], release: Int, held: [String: String?] = [:], shareRoot: String
    ) throws -> [UpgradeOldFile] {
        let found = try upgradeOldFiles(sharePaths, shareRoot: shareRoot)
        for file in found {
            let expected = held[file.sharePath] ?? String(release)
            guard file.release == expected else {
                throw UpgradeRefusal.otherRelease(
                    file.path, found: file.release, expected: expected)
            }
        }
        return found
    }
}

extension LibraryIndex {
    /// The files of the library album `album`, relative to the share mounted at `shareRoot`,
    /// in disc and track order; nil when any isn't on the share.
    package func albumFiles(_ album: Int64, shareRoot: String) throws -> [String]? {
        let files = try statement(
            """
            SELECT f.path FROM tracks t JOIN files f ON f.id = t.file_id WHERE t.album_id = ?
            ORDER BY t.disc_number IS NULL, t.disc_number, t.track_number IS NULL,
                t.track_number, f.path
            """
        ).map(album) { try $0.text(0) }
        guard files.allSatisfy({ isPath($0, under: shareRoot) }) else { return nil }
        return files.map { String($0.dropFirst(stem(shareRoot).count + 1)) }
    }
}

extension LibraryFolderMove {
    /// The files `sharePaths`, relative to the share, as the paths `destinations` compares.
    package func libraryPaths(_ sharePaths: [String]) -> Set<String> {
        Set(sharePaths.map { (stem(shareRoot) + "/" + $0).precomposedStringWithCanonicalMapping })
    }
}
