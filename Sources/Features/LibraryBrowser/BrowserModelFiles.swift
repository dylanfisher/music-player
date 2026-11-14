import Foundation
import Library

/// The model's imports from another player and its exports, of a playlist and of the library's
/// profile.
extension BrowserModel {
    /// What importing `library` would change.
    func importPlan(_ library: PlayerLibrary, prefix: PathPrefix?) async throws -> ImportPlan {
        try await reader.importPlan(library, prefix: prefix)
    }

    /// Writes an import, and shows what it changed.
    func applyImport(_ library: PlayerLibrary, prefix: PathPrefix?) async throws -> ImportPlan {
        let plan = try await reader.applyImport(library, prefix: prefix)
        try await reloadPlaylists()
        await refresh()
        return plan
    }

    /// Writes the playlist `id` to `url` as M3U8, in the table's sort.
    func exportPlaylist(_ id: Int64, to url: URL, relativePaths: Bool) async throws -> (
        written: Int, unwritable: [String]
    ) {
        try await reader.exportPlaylist(
            id, sortedBy: sortColumn, ascending: ascending,
            groupByAlbumArtist: filter.groupByAlbumArtist, to: url, relativePaths: relativePaths)
    }

    /// Writes the library's profile for music-recommender to `url`, and returns how many albums
    /// it holds.
    func exportLibraryProfile(to url: URL) async throws -> Int {
        try await reader.writeLibraryProfile(to: url)
    }
}
