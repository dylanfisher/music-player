import Foundation
import Library

/// The tables of a Swinsian library database, as read from the owner's on 2026-11-01
/// (ADR 0033), for generated databases. Podcasts and the queue are left out.
public let swinsianSchemaSQL = """
    CREATE TABLE library (id INTEGER PRIMARY KEY, version INTEGER, applescriptid TEXT, uuid FLOAT, sortkey TEXT, ascending INTEGER);
    CREATE TABLE track (track_id INTEGER PRIMARY KEY, title TEXT, artist TEXT, album TEXT, genre TEXT, composer TEXT, year INTEGER, tracknumber INTEGER, discnumber INTEGER, bitrate INTEGER, bitdepth INTEGER, samplerate INTEGER, channels INTEGER, length FLOAT, dateadded FLOAT, lastplayed FLOAT, playcount INTEGER, rating INTEGER, filesize INTEGER, enabled INTEGER, cue INTEGER, gapless INTEGER, compilation INTEGER, encoder TEXT, path TEXT, filename TEXT, comment TEXT, properties_id INTEGER, albumartist TEXT, totaldiscnumber INTEGER, datecreated FLOAT, grouping TEXT, bpm INTEGER, publisher TEXT, totaltracknumber INTEGER, description TEXT, datemodified FLOAT, catalognumber TEXT, conductor TEXT, discsubtitle TEXT, lyrics TEXT, copyright TEXT , starttime INTEGER, stoptime INTEGER, trackvolume FLOAT, millisecondlength INTEGER, sortartist TEXT, sortalbum TEXT, sortalbumartist TEXT, lyricist TEXT, barcode TEXT, work TEXT, movementname TEXT, movement INTEGER, originalreleasedate TEXT, initialkey TEXT, sortcomposer TEXT, favourite INTEGER, filetype INTEGER);
    CREATE TABLE trackproperties (properties_id INTEGER PRIMARY KEY, alias BLOB, applescriptid TEXT, startsilence INTEGER, endsilence INTEGER, cueoffset INTEGER, bookmark BLOB);
    CREATE TABLE playlist (playlist_id INTEGER PRIMARY KEY, name TEXT, pindex INTEGER, applescriptid TEXT, smart INTEGER, smartpredicate BLOB, sortkey TEXT, ascending INTEGER, folder INTEGER, expanded INTEGER, itunes_id TEXT, limited INTEGER, limitcount INTEGER, limittype INTEGER, limitsort INTEGER);
    CREATE TABLE playlisttrack (id INTEGER PRIMARY KEY, playlist_id INTEGER, track_id INTEGER, tindex INTEGER);
    CREATE TABLE playlistfolderplaylist (id INTEGER PRIMARY KEY, playlistfolder_id INTEGER, playlist_id INTEGER, pindex INTEGER);
    CREATE TABLE topplaylist (topplaylist_id INTEGER PRIMARY KEY, pindex INTEGER UNIQUE, playlist_id INTEGER);
    CREATE INDEX filename_index ON track (filename COLLATE NOCASE);
    CREATE INDEX path_index ON track (path);
    CREATE INDEX playlist_track_index ON playlisttrack (playlist_id);

    """

/// The shapes of the owner's 18 smart playlists' rules, in `NSPredicate` format, with generic
/// genres in place of the owner's.
public let swinsianPredicateShapes = [
    #"dateAdded > CAST(CAST(now(), "NSNumber") - 86400, "NSDate")"#,
    #"dateAdded > CAST(CAST(now(), "NSNumber") - 604800, "NSDate")"#,
    #"dateAdded > CAST(CAST(now(), "NSNumber") - 2592000, "NSDate")"#,
    #"bitRate > 1000"#,
    #"lastPlayed > CAST(CAST(now(), "NSNumber") - 604800, "NSDate")"#,
    #"genre BEGINSWITH[c] "Genre A - ""#,
    #"genre BEGINSWITH[c] "Genre B - ""#,
    #"genre BEGINSWITH[c] "Genre C - ""#,
    #"genre BEGINSWITH[c] "Genre D - ""#,
    #"genre BEGINSWITH[c] "Genre E - ""#,
    #"genre BEGINSWITH[c] "Genre E - " AND genre CONTAINS[c] "Style F" AND (NOT (genre CONTAINS[c] "Style G" OR genre CONTAINS[c] "Style H"))"#,
    #"fileType ==[c] "dsf" OR fileType ==[c] "dsd""#,
    #"sampleRate > 44100"#,
    #"genre BEGINSWITH[c] "Genre F - ""#,
    #"groupingLength > 0"#,
    #"genre BEGINSWITH[c] "Genre A - " AND genre CONTAINS[c] "Style I""#,
    #"genre BEGINSWITH[c] "Genre A - " AND genre CONTAINS[c] "Style J""#,
    #"genre BEGINSWITH[c] "Genre A - " AND genre CONTAINS[c] "Style J K""#,
]

/// `format` as Swinsian stores a smart playlist's rules: an `NSPredicate` archived by
/// `NSKeyedArchiver`.
public func swinsianPredicateArchive(_ format: String) throws -> [UInt8] {
    [UInt8](
        try NSKeyedArchiver.archivedData(
            withRootObject: NSPredicate(format: format), requiringSecureCoding: true))
}

/// Swinsian's preferences file with only its track table's keys, in the shape the owner's had
/// on 2026-11-02 (ADR 0055): the visible columns, left to right, by ID with their widths, and
/// the sort, an `NSKeyedArchiver` archive of the dictionaries `NSTableView` saves. The keys are
/// the reader's; its tests check them against the owner's file.
public func swinsianPreferences(columns: [(id: String, width: Double)], sort: (String, Bool)?)
    throws -> Data
{
    var root: [String: Any] = [
        SwinsianColumns.columnsKey: columns.map {
            [SwinsianColumns.columnIDKey: $0.id, SwinsianColumns.columnWidthKey: $0.width]
        }
    ]
    if let (id, ascending) = sort {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.encode(
            [[SwinsianColumns.sortIDKey: id, SwinsianColumns.sortAscendingKey: ascending]]
                as NSArray, forKey: "Array")
        archiver.finishEncoding()
        root[SwinsianColumns.sortKey] = archiver.encodedData
    }
    return try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
}
