import Foundation
import Settings

/// Playlist files: an import is an index lookup of the paths a file names, never a read of
/// them (ADR 0025); an export writes only where the user chose.
extension LibraryIndex {
    /// Makes a manual playlist called `name` of the tracks `file` names that the index holds.
    func importPlaylist(named name: String, _ file: PlaylistFile, from source: String)
        throws -> PlaylistImport
    {
        let ids = try trackIDs(atPaths: file.paths)
        let found = ids.compactMap { $0 }
        return try database.transaction {
            let id = try createPlaylist(named: name)
            let added = try appendEntries(id, found)
            return PlaylistImport(
                playlistID: id, name: name, source: source, added: added,
                missing: zip(file.paths, ids).compactMap { $1 == nil ? $0 : nil },
                repeated: found.count - added, file: file)
        }
    }

    /// The track ID of each path, or nil where the index has none. A path matches as written,
    /// then in NFC: names a share lists precomposed sit under a root kept decomposed (ADR 0009),
    /// and other players write either form.
    func trackIDs(atPaths paths: [String]) throws -> [Int64?] {
        let select = try statement(
            "SELECT t.file_id FROM files f JOIN tracks t ON t.file_id = f.id WHERE f.path = ?")
        var byNFC: [String: Int64]?
        var ids: [Int64?] = []
        for path in paths {
            if let id = try select.map(path, row: { try $0.int64(0) }).first {
                ids.append(id)
                continue
            }
            if byNFC == nil {
                byNFC = Dictionary(
                    try statement(
                        "SELECT f.path, t.file_id FROM files f JOIN tracks t ON t.file_id = f.id"
                    ).map {
                        (try $0.text(0).precomposedStringWithCanonicalMapping, try $0.int64(1))
                    },
                    uniquingKeysWith: min)
            }
            ids.append(byNFC?[path.precomposedStringWithCanonicalMapping])
        }
        return ids
    }

    /// A playlist's tracks in the order `column` sorts them, for writing to a file. A manual
    /// playlist's entries that left the index aren't among them; `missingEntryCount` counts them.
    func playlistFileTracks(
        _ id: Int64, sortedBy column: TrackColumn, ascending: Bool, groupByAlbumArtist: Bool
    ) throws -> [PlaylistFileTrack] {
        let ids = try trackIDs(
            TrackFilter(source: .playlist(id), groupByAlbumArtist: groupByAlbumArtist),
            sortedBy: column, ascending: ascending)
        return try rows(ids: ids).map(PlaylistFileTrack.init)
    }
}
