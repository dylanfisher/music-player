import Foundation
import Log
import SQLite
import Settings

private let logger = moduleLogger()

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

    /// The shared name of `source`: its text, with a playlist named by its sync ID. Nil for the
    /// library, and for a playlist without a sync ID, which is logged.
    public func sharedName(of source: BrowserSource?) throws -> String? {
        guard case .playlist(let id) = source else { return source?.text }
        guard let syncID = try syncID(ofPlaylist: id) else {
            logger.notice("playlist \(id) has no sync ID; the play state names the library")
            return nil
        }
        return BrowserSource.playlistPrefix + syncID
    }

    /// The source the shared name `name` is on this Mac, nil for the library. A playlist this
    /// Mac doesn't have, or a name that isn't a source, is the library, logged.
    public func source(sharedName name: String?) throws -> BrowserSource? {
        guard let name else { return nil }
        if name.hasPrefix(BrowserSource.playlistPrefix) {
            let syncID = String(name.dropFirst(BrowserSource.playlistPrefix.count))
            if let id = try playlistID(syncID: syncID) { return .playlist(id) }
        } else if let source = BrowserSource(text: name) {
            return source
        }
        logger.notice("the saved source \(name) isn't here; showing the library")
        return nil
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
