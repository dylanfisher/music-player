import Darwin
import Foundation
import Recommender

extension LibraryIndex {
    /// Every album as music-recommender's profile has it, read from the index alone (ADR 0198),
    /// its artist and release id by `profileIdentity`. Tracks without an album aren't in an
    /// album to send.
    package func libraryProfile() throws -> LibraryProfile {
        let rows = try database.prepare(
            """
            SELECT t.album_id, a.title, ar.name, t.length_frames, t.sample_rate_hz,
                t.catalog_number, t.barcode, t.discogs_release_id, max(0, ifnull(p.play_count, 0)),
                \(lovedSQL)
            FROM tracks t JOIN albums a ON a.id = t.album_id JOIN files f ON f.id = t.file_id
            LEFT JOIN artists ar ON ar.id = a.artist_id
            LEFT JOIN plays p ON p.path_id = t.file_id
            LEFT JOIN \(lovedTable) lv ON lv.path_id = t.file_id
            ORDER BY t.album_id, t.disc_number IS NULL, t.disc_number, t.track_number IS NULL,
                t.track_number, f.path
            """
        ).map { row in
            let rateHz = try row.int(4)
            return (
                album: try row.int64(0), title: try row.text(1), artist: row.optionalText(2),
                seconds: rateHz > 0 ? Int((Double(try row.int(3)) / Double(rateHz)).rounded()) : 0,
                catalogNumber: row.optionalText(5), barcode: row.optionalText(6),
                release: row.optionalText(7), plays: try row.int(8), loved: try row.int(9) == 1
            )
        }
        var albums: [LibraryProfile.Album] = []
        var start = rows.startIndex
        while start < rows.endIndex {
            let album = rows[start].album
            let end = rows[start...].firstIndex { $0.album != album } ?? rows.endIndex
            let tracks = rows[start..<end]
            start = end
            let first = tracks[tracks.startIndex]
            let identity = profileIdentity(artist: first.artist, releases: tracks.map(\.release))
            albums.append(
                LibraryProfile.Album(
                    artist: identity.artist, title: first.title,
                    durations: tracks.map(\.seconds),
                    catalogNumbers: distinct(tracks.compactMap(\.catalogNumber)),
                    barcodes: distinct(tracks.compactMap(\.barcode)),
                    discogsReleaseID: identity.releaseID,
                    plays: tracks.map(\.plays).reduce(0, +),
                    loved: tracks.filter(\.loved).count))
        }
        return LibraryProfile(albums: albums)
    }

    /// The albums of the tracks `ids`, each once in the order first met, with its title and
    /// the artist and release id the profile sends for it, read from all its tracks: the seeds
    /// Recommendations for Album and for Artist ask the service for.
    package func recommendationSeeds(trackIDs ids: [Int64]) throws -> [(
        title: String, artist: String, releaseID: Int?
    )] {
        let albumOf = try statement(
            "SELECT album_id FROM tracks WHERE file_id = ? AND album_id IS NOT NULL")
        var albums: [Int64] = []
        for id in ids {
            for album in try albumOf.map(id, row: { try $0.int64(0) }) where !albums.contains(album)
            {
                albums.append(album)
            }
        }
        let tracks = try statement(
            """
            SELECT a.title, ar.name, t.discogs_release_id
            FROM tracks t JOIN albums a ON a.id = t.album_id
            LEFT JOIN artists ar ON ar.id = a.artist_id
            WHERE t.album_id = ?
            """)
        return try albums.compactMap { album in
            let rows = try tracks.map(album) {
                (title: try $0.text(0), artist: $0.optionalText(1), release: $0.optionalText(2))
            }
            guard let first = rows.first else { return nil }
            let identity = profileIdentity(artist: first.artist, releases: rows.map(\.release))
            return (first.title, identity.artist, identity.releaseID)
        }
    }

    /// Writes `libraryProfile()` to `url` as JSON, in place of any file there, and returns how
    /// many albums it holds. A link, or a file the index holds, at `url` is refused, so a slip
    /// in the save panel can't replace a music file or a file a link names (ADR 0025, row 76).
    package func writeLibraryProfile(to url: URL) throws -> Int {
        var info = stat()
        if lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK {
            throw ProfileDestinationRefusal.link(url.path)
        }
        let folder = url.deletingLastPathComponent().path
        let real = resolved(folder).map { $0 + "/" + url.lastPathComponent }
        for path in [url.path, real].compactMap({ $0 }) where try track(path: path) != nil {
            throw ProfileDestinationRefusal.indexed(path)
        }
        let profile = try libraryProfile()
        try profile.json().write(to: url, options: .atomic)
        return profile.albums.count
    }
}

/// Why the profile isn't written where the owner chose.
enum ProfileDestinationRefusal: Error, Equatable, CustomStringConvertible {
    /// A symbolic link is there.
    case link(String)
    /// A file of the library is there.
    case indexed(String)

    var description: String {
        switch self {
        case .link(let path): "\(path) is a link, so the profile isn't written over it"
        case .indexed(let path): "\(path) is in the library, so the profile isn't written over it"
        }
    }
}

/// An album's artist and release id as the profile sends them, so a seed asked for from the
/// selection names what the service has. The artist is the album's (its album artist, else its
/// track artist), else `variousArtists`; the release id is the one every track carries, as a
/// positive number, as ADR 0129 matches an album, else none. `releases` holds each track's tag.
func profileIdentity(artist: String?, releases: [String?]) -> (artist: String, releaseID: Int?) {
    let distinct = Set(releases)
    let release = distinct.count == 1 ? distinct.first?.flatMap { Int($0) } : nil
    return (artist ?? variousArtists, release.flatMap { $0 > 0 ? $0 : nil })
}

/// `values` without repeats, in their first order.
private func distinct(_ values: [String]) -> [String] {
    var seen: Set<String> = []
    return values.filter { seen.insert($0).inserted }
}
