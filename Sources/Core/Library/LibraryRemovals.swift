import Foundation

extension LibraryIndex {
    /// Takes the tracks `ids` out of the library and keeps their paths out of every later scan
    /// until they're restored. The paths keep their stats (ADR 0050).
    func removeFromLibrary(trackIDs ids: [Int64]) throws {
        try database.transaction {
            let exclude = try statement(
                "INSERT OR IGNORE INTO \(removedTable) (path_id) VALUES (?)")
            for id in ids {
                try exclude.run(id)
                try deleteFile(id)
            }
        }
        try deleteOrphans()
    }

    /// Takes the tracks `ids`, whose files went to the Trash, out of the library. Their paths
    /// aren't offered in Lost Stats; a file put back is read by the next scan, which keeps its
    /// stats.
    func forgetTrashed(trackIDs ids: [Int64]) throws {
        try database.transaction {
            let dismiss = try statement(dismissLostSQL)
            for id in ids {
                try dismiss.run(id)
                try deleteFile(id)
            }
        }
        try deleteOrphans()
    }

    /// Every removed path, in path order.
    func removedPaths() throws -> [RemovedPath] {
        try statement(
            "SELECT p.id, p.path FROM \(removedTable) r JOIN paths p ON p.id = r.path_id"
                + " ORDER BY p.path"
        ).map { RemovedPath(id: try $0.int64(0), path: try $0.text(1)) }
    }

    /// The removed paths in NFC, for a scan to skip.
    func removedPathSet() throws -> Set<String> {
        Set(try removedPaths().map(\.path))
    }

    /// Lets scans add the removed paths `ids` again, and returns their paths.
    func restoreRemoved(_ ids: [Int64]) throws -> [String] {
        try database.transaction {
            let path = try statement(
                "SELECT p.path FROM \(removedTable) r JOIN paths p ON p.id = r.path_id"
                    + " WHERE r.path_id = ?")
            let restore = try statement(restoreRemovedSQL)
            return try ids.flatMap { id in
                let found = try path.map(id) { try $0.text(0) }
                try restore.run(id)
                return found
            }
        }
    }
}

/// Lets scans add a removed path again.
let restoreRemovedSQL = "DELETE FROM \(removedTable) WHERE path_id = ?"

/// A path the user removed from the library.
public struct RemovedPath: Equatable, Sendable {
    public var id: Int64
    /// In NFC, as `paths` keeps it.
    public var path: String
}
