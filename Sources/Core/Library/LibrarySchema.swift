// The SQL of each part is also its identity: the database stores the text it was built from,
// and any difference on open rebuilds that part (pre-release, so no migrations). Only use
// SQLite features from 3.36 or earlier, the version macOS 12 ships: no STRICT tables,
// unixepoch() or JSONB.

/// The parts of the database that are rebuilt independently.
enum SchemaPart: String, CaseIterable {
    /// Everything a scan can rebuild from the files: dropped and recreated when its SQL changes.
    case index
    /// The paths' permanent IDs, plays, ratings, history and playlists, which no scan can
    /// recreate. Keyed by path ID (ADR 0022), so a rebuilt index finds them again.
    case stats

    var sql: String {
        switch self {
        case .index: indexSchema
        case .stats: statsSchema
        }
    }
}

/// Holds the SQL each part was last built from. Its own shape never changes.
let schemaIdentityTable = "schema_identity"

/// What each stats rebuild discarded, until the window has shown it. Its own shape never
/// changes either, and no rebuild drops it.
let schemaDiscardsTable = "schema_discards"

/// The tables `statsSchema` creates, which an index rebuild keeps.
let statsTables: Set<String> = [
    "paths", "plays", "ratings", "history", "playlists", "playlist_entries",
]

private let indexSchema = """
    CREATE TABLE files (
        -- The path's ID in paths, which an index rebuild keeps.
        id INTEGER PRIMARY KEY REFERENCES paths (id),
        path TEXT NOT NULL UNIQUE,
        size_bytes INTEGER NOT NULL,
        -- Seconds since 1970, compared exactly with the walk's value to skip unchanged files.
        modified_seconds REAL NOT NULL,
        -- Set when the file couldn't be read; MetadataError.Kind's raw value.
        failure_kind TEXT,
        failure_offset INTEGER,
        failure_detail TEXT
    );
    CREATE TABLE artists (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL UNIQUE,
        sort_name TEXT NOT NULL
    );
    CREATE INDEX artists_sort ON artists (sort_name);
    CREATE TABLE genres (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL UNIQUE,
        sort_name TEXT NOT NULL
    );
    CREATE TABLE albums (
        id INTEGER PRIMARY KEY,
        title TEXT NOT NULL,
        -- The album artist, else the track artist; NULL for a compilation without one.
        artist_id INTEGER REFERENCES artists (id),
        sort_title TEXT NOT NULL
    );
    CREATE UNIQUE INDEX albums_identity ON albums (title, ifnull(artist_id, 0));
    CREATE TABLE tracks (
        file_id INTEGER PRIMARY KEY REFERENCES files (id) ON DELETE CASCADE,
        title TEXT,
        -- The title, or the file name without its extension, folded for sorting.
        sort_title TEXT NOT NULL,
        artist_id INTEGER REFERENCES artists (id),
        album_artist_id INTEGER REFERENCES artists (id),
        album_id INTEGER REFERENCES albums (id),
        genre_id INTEGER REFERENCES genres (id),
        date TEXT,
        track_number INTEGER,
        track_total INTEGER,
        disc_number INTEGER,
        disc_total INTEGER,
        compilation INTEGER NOT NULL,
        composer TEXT,
        comment TEXT,
        codec TEXT NOT NULL,
        sample_rate_hz INTEGER NOT NULL,
        bits_per_sample INTEGER,
        channels INTEGER NOT NULL,
        length_frames INTEGER NOT NULL,
        art_offset INTEGER,
        art_byte_count INTEGER,
        art_mime_type TEXT,
        art_unsynchronised INTEGER
    );
    CREATE INDEX tracks_genre_artist ON tracks (genre_id, artist_id);
    CREATE INDEX tracks_artist_album ON tracks (artist_id, album_id);
    CREATE INDEX tracks_album ON tracks (album_id);
    CREATE INDEX tracks_album_artist ON tracks (album_artist_id);
    CREATE TABLE warnings (
        file_id INTEGER NOT NULL REFERENCES files (id) ON DELETE CASCADE,
        -- MetadataWarning.Kind's raw value.
        kind TEXT NOT NULL,
        offset INTEGER NOT NULL,
        detail TEXT NOT NULL
    );
    CREATE INDEX warnings_file ON warnings (file_id);
    -- rowid is files.id. The prefix indexes make "abc*" queries as you type cheap.
    CREATE VIRTUAL TABLE track_search USING fts5 (
        title, artist, album, album_artist, genre, composer,
        tokenize = 'unicode61 remove_diacritics 2', prefix = '1 2 3'
    );
    """

private let statsSchema = """
    -- Every path the library has seen. Rows are never deleted, so a file that leaves the index
    -- and comes back keeps its ID, its Date Added and its stats (ADR 0022).
    CREATE TABLE paths (
        id INTEGER PRIMARY KEY,
        path TEXT NOT NULL UNIQUE,
        -- When the path was first seen, in seconds since 1970: the "date added" column.
        added_seconds REAL NOT NULL
    );
    CREATE TABLE plays (
        path_id INTEGER PRIMARY KEY REFERENCES paths (id),
        play_count INTEGER NOT NULL,
        skip_count INTEGER NOT NULL,
        last_played_seconds REAL
    );
    -- History lists played tracks in this order, so it reads them without sorting.
    CREATE INDEX plays_last_played ON plays (last_played_seconds);
    CREATE TABLE ratings (
        path_id INTEGER PRIMARY KEY REFERENCES paths (id),
        rating INTEGER NOT NULL
    );
    -- Append-only, so id order is the order plays were recorded and played_at needs no index.
    CREATE TABLE history (
        id INTEGER PRIMARY KEY,
        path_id INTEGER NOT NULL REFERENCES paths (id),
        -- Whole seconds since 1970.
        played_at INTEGER NOT NULL
    );
    CREATE INDEX history_path ON history (path_id);
    -- AUTOINCREMENT, so a deleted playlist's ID is never reused: the state file and the
    -- palette's frecency name playlists by ID.
    CREATE TABLE playlists (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        -- A smart playlist's SmartRules as JSON; NULL for a manual playlist.
        rules TEXT
    );
    -- Each track at most once per playlist, in position order.
    CREATE TABLE playlist_entries (
        playlist_id INTEGER NOT NULL REFERENCES playlists (id) ON DELETE CASCADE,
        path_id INTEGER NOT NULL REFERENCES paths (id),
        position INTEGER NOT NULL,
        PRIMARY KEY (playlist_id, path_id)
    );
    CREATE INDEX playlist_entries_order ON playlist_entries (playlist_id, position);
    """
