import Foundation
import SQLite

/// Names for a track and a playlist that every Mac reads the same way, for the play state the
/// config file carries between them (ADR 0092). A track under a folder stored by share is its
/// sync path (ADR 0038), which each Mac maps to where it mounts the share; any other track is
/// its absolute path, which starts with `/` and finds the track only on a Mac with the same
/// path. A playlist is its sync ID.
extension LibraryIndex {
    /// The shared name of track `id`; nil when the index has no such track.
    public func sharedName(ofTrack id: Int64) throws -> String? {
        guard
            let path = try statement(
                "SELECT p.path FROM paths p JOIN files f ON f.id = p.id WHERE p.id = ?"
            ).map(id, row: { try $0.text(0) }).first
        else { return nil }
        return try syncRoots().syncPath(path) ?? path
    }

    /// The track the shared name `name` is on this Mac; nil when the index has none there.
    public func trackID(sharedName name: String) throws -> Int64? {
        let normalized = name.precomposedStringWithCanonicalMapping
        guard
            let path = normalized.hasPrefix("/")
                ? normalized : try syncRoots().localPath(normalized)
        else { return nil }
        return try statement(
            "SELECT f.id FROM paths p JOIN files f ON f.id = p.id WHERE p.path = ?"
        ).map(path, row: { try $0.int64(0) }).first
    }

    /// Playlist `id`'s sync ID; nil for one made before sync and not changed since.
    public func syncID(ofPlaylist id: Int64) throws -> String? {
        try statement(syncPlaylistIDSQL).map(id, row: { try $0.text(0) }).first
    }

    /// The playlist with sync ID `syncID` on this Mac; nil when there's none, or it was deleted.
    public func playlistID(syncID: String) throws -> Int64? {
        try statement("SELECT playlist_id FROM \(syncPlaylistsTable) WHERE id = ?")
            .map(syncID, row: { $0.optionalInt(0).map(Int64.init) }).first ?? nil
    }
}
