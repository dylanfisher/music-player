import DisplayText
import Settings

/// What each health check found (ADR 0034): built in one read of the index, on request and when
/// a scan ends.
public struct HealthReport: Equatable, Sendable {
    private var findings: [HealthCheck: HealthFindings]

    init(_ findings: [HealthCheck: HealthFindings]) {
        precondition(Set(findings.keys) == Set(HealthCheck.allCases), "a check is missing")
        self.findings = findings
    }

    public subscript(_ check: HealthCheck) -> HealthFindings {
        guard let found = findings[check] else { preconditionFailure("\(check) wasn't run") }
        return found
    }
}

/// One check's tracks, and what it found that the track table can't list.
public struct HealthFindings: Equatable, Sendable {
    /// In ID order.
    public var trackIDs: [Int64] = []
    /// What isn't a track, such as a file never read or a playlist entry whose file left, one
    /// line each, the first `healthLinesListed`.
    public var lines: [String] = []
    /// Every such item, listed or not.
    public var otherCount = 0

    /// Tracks and other items together.
    public var count: Int { trackIDs.count + otherCount }

    init(trackIDs: [Int64] = [], others: [String] = []) {
        self.trackIDs = trackIDs
        lines = Array(others.prefix(healthLinesListed))
        if others.count > healthLinesListed {
            lines.append("… and \(others.count - healthLinesListed) more")
        }
        otherCount = others.count
    }
}

/// How many items that aren't tracks a check lists before it counts the rest.
let healthLinesListed = 100

extension HealthCheck {
    /// The sidebar's name for the check, short enough to leave room for its count.
    public var title: String {
        switch self {
        case .unreadable: "Unreadable"
        case .warnings: "Warnings"
        case .missingEntries: "Lost Entries"
        case .sameNumber: "Same Number"
        case .sameTitle: "Same Title"
        case .trackGaps: "Track Gaps"
        case .severalAlbumArtists: "Album Artists"
        case .mixedSampleRates: "Mixed Rates"
        case .noArt: "No Art"
        case .noAlbum: "No Album"
        case .noAlbumArtist: "No Album Artist"
        }
    }

    /// What the check finds, for the row's tooltip.
    public var summary: String {
        switch self {
        case .unreadable: "Files the scanner couldn't read"
        case .warnings: "Files read with a field read in part or dropped"
        case .missingEntries: "Playlist entries whose file left the library"
        case .sameNumber: "Tracks with the same album, disc and track number"
        case .sameTitle: "Tracks with the same title and artist, within a second of the same length"
        case .trackGaps: "Albums missing a track number below their highest"
        case .severalAlbumArtists: "One album in one folder under more than one album artist"
        case .mixedSampleRates: "Albums with more than one sample rate"
        case .noArt: "Tracks with no embedded art"
        case .noAlbum: "Tracks with no album"
        case .noAlbumArtist: "Tracks with no album artist"
        }
    }
}

extension LibraryIndex {
    /// Runs every check in one read, so they all see the same library while a scan writes.
    public func healthReport() throws -> HealthReport {
        try database.deferredTransaction {
            HealthReport(
                Dictionary(
                    uniqueKeysWithValues: try HealthCheck.allCases.map { ($0, try run($0)) }))
        }
    }

    /// One check. A new check is a case here and in `HealthCheck`.
    private func run(_ check: HealthCheck) throws -> HealthFindings {
        switch check {
        case .unreadable:
            let others = try statement(
                """
                SELECT path, failure_kind, failure_offset, failure_detail FROM files f
                WHERE failure_kind IS NOT NULL
                    AND NOT EXISTS (SELECT 1 FROM tracks WHERE file_id = f.id)
                ORDER BY path
                """
            ).map { try failureIssue($0).description }
            return HealthFindings(
                trackIDs: try ids(
                    "SELECT t.file_id FROM tracks t JOIN files f ON f.id = t.file_id"
                        + " WHERE f.failure_kind IS NOT NULL"),
                others: others.map(terminalSafe))
        case .warnings:
            return HealthFindings(
                trackIDs: try ids(
                    "SELECT file_id FROM tracks WHERE file_id IN (SELECT file_id FROM warnings)"))
        case .missingEntries:
            // As `missingEntryCount` counts them: an entry with no track.
            let others = try statement(
                """
                SELECT pl.name, p.path FROM playlist_entries e
                JOIN playlists pl ON pl.id = e.playlist_id JOIN paths p ON p.id = e.path_id
                WHERE NOT EXISTS (SELECT 1 FROM tracks t WHERE t.file_id = e.path_id)
                ORDER BY pl.name, pl.id, e.position
                """
            ).map { row in terminalSafe("\(try row.text(0)): \(try row.text(1))") }
            return HealthFindings(others: others)
        case .sameNumber:
            return HealthFindings(
                trackIDs: try ids(
                    """
                    WITH a AS (\(albumTracks))
                    SELECT a.file_id FROM a JOIN (
                        SELECT album_id, folder, disc, track_number FROM a
                        WHERE track_number IS NOT NULL GROUP BY 1, 2, 3, 4 HAVING count(*) > 1
                    ) d USING (album_id, folder, disc, track_number)
                    """))
        case .sameTitle:
            let rows = try statement(
                """
                SELECT file_id, title, artist_id, CAST(length_frames AS REAL) / sample_rate_hz
                FROM tracks
                WHERE title IS NOT NULL AND artist_id IS NOT NULL AND sample_rate_hz > 0
                    AND length_frames > 0
                ORDER BY title, artist_id, 4
                """
            ).map { row in
                TitledTrack(
                    id: try row.int64(0), title: try row.text(1), artist: try row.int64(2),
                    seconds: try row.double(3))
            }
            return HealthFindings(trackIDs: sameTitleAndLength(rows))
        case .trackGaps:
            // A later disc may go on from the last one's numbers, so it counts from its lowest.
            return HealthFindings(
                trackIDs: try ids(
                    """
                    WITH a AS (\(albumTracks))
                    SELECT a.file_id FROM a JOIN (
                        SELECT album_id, folder, disc FROM a WHERE track_number > 0
                        GROUP BY 1, 2, 3
                        HAVING count(DISTINCT track_number) < max(track_number)
                            - CASE WHEN disc > 1 THEN min(track_number) - 1 ELSE 0 END
                    ) g USING (album_id, folder, disc)
                    """))
        case .severalAlbumArtists:
            // The index splits an album by album artist, so one album is its title in a folder.
            // A track without one is listed under No Album Artist, and joins its track artist's album.
            return HealthFindings(
                trackIDs: try ids(
                    """
                    SELECT t.file_id FROM tracks t JOIN albums al ON al.id = t.album_id
                    JOIN files f ON f.id = t.file_id
                    WHERE (al.title, \(folderSQL)) IN (
                        SELECT al.title, \(folderSQL) FROM tracks t
                        JOIN albums al ON al.id = t.album_id JOIN files f ON f.id = t.file_id
                        GROUP BY 1, 2 HAVING count(DISTINCT t.album_artist_id) > 1)
                    """))
        case .mixedSampleRates:
            return HealthFindings(
                trackIDs: try ids(
                    """
                    WITH a AS (\(albumTracks))
                    SELECT a.file_id FROM a JOIN (
                        SELECT album_id, folder FROM a
                        GROUP BY 1, 2 HAVING count(DISTINCT sample_rate_hz) > 1
                    ) m USING (album_id, folder)
                    """))
        case .noArt:
            return HealthFindings(
                trackIDs: try ids("SELECT file_id FROM tracks WHERE art_offset IS NULL"))
        case .noAlbum:
            return HealthFindings(
                trackIDs: try ids("SELECT file_id FROM tracks WHERE album_id IS NULL"))
        case .noAlbumArtist:
            return HealthFindings(
                trackIDs: try ids("SELECT file_id FROM tracks WHERE album_artist_id IS NULL"))
        }
    }

    /// The IDs `sql` selects, in ID order.
    private func ids(_ sql: String) throws -> [Int64] {
        try statement(sql + " ORDER BY 1").map { try $0.int64(0) }
    }

    /// Keeps `report`'s tracks on this connection, for the `.health` sources to list.
    public func showHealth(_ report: HealthReport) throws {
        // Deferred, since an immediate transaction would wait for a scan's writes to the file.
        try database.deferredTransaction {
            try statement("DELETE FROM \(healthTracksTable)").run()
            let insert = try statement(
                "INSERT INTO \(healthTracksTable) (check_name, file_id) VALUES (?, ?)")
            for check in HealthCheck.allCases {
                for id in report[check].trackIDs { try insert.run(check.rawValue, id) }
            }
        }
    }
}

/// The folder of file `f`'s path, with its trailing slash.
private let folderSQL = "substr(f.path, 1, f.name_offset - 1)"

/// Each track on an album, with the album's folder and disc (none is 0): two releases with one
/// title and album artist are one album row in the index, but rarely share a folder.
private let albumTracks = """
    SELECT t.file_id, t.album_id, \(folderSQL) AS folder, ifnull(t.disc_number, 0) AS disc,
        t.track_number, t.sample_rate_hz
    FROM tracks t JOIN files f ON f.id = t.file_id WHERE t.album_id IS NOT NULL
    """

/// A connection's own table of the health report it shows, so a `.health` source is a
/// condition like any other. Temporary: it belongs to the window's reader, not the library.
let healthTracksTable = "temp.health_tracks"

let healthTracksSchema = """
    CREATE TEMP TABLE IF NOT EXISTS health_tracks (
        check_name TEXT NOT NULL, file_id INTEGER NOT NULL, PRIMARY KEY (check_name, file_id)
    ) WITHOUT ROWID
    """

/// A track as the title check sorts it.
struct TitledTrack {
    var id: Int64
    var title: String
    var artist: Int64
    var seconds: Double
}

/// The tracks of `sorted`, ordered by title, artist and length, that share a title and artist
/// with a neighbor no more than a second longer or shorter. One pass, after the sort.
func sameTitleAndLength(_ sorted: [TitledTrack]) -> [Int64] {
    var found = Set<Int64>()
    for (previous, track) in zip(sorted, sorted.dropFirst())
    where track.title == previous.title && track.artist == previous.artist
        && track.seconds - previous.seconds <= 1
    {
        found.insert(previous.id)
        found.insert(track.id)
    }
    return found.sorted()
}
