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
    /// Loved tracks, also keyed by path ID. A part of its own, so its shape can change without
    /// discarding the other stats (ADR 0031).
    case loved
    /// Disliked tracks, keyed by path ID, a part of their own so adding them kept the loved
    /// ones (ADR 0048). A path is loved or disliked, never both.
    case disliked
    /// What each import from another player counted, so a second import adds only what grew
    /// (ADR 0033). A part of its own for the same reason as `loved`.
    case imports
    /// Each import's last play of a path, the one dated play of its counted plays (ADR 0105).
    /// A part of its own so adding it kept the import counts, which a second import needs.
    case importedLastPlays
    /// This machine's log and what it read of the others' (ADR 0038). Rebuilding it from an
    /// earlier shape rebuilds the stats too: the new machine ID reads every log from the
    /// start, its own old one included, which the old stats already hold.
    case sync
    /// Which watched folders' last whole scan finished (ADR 0040). Rebuilt with the index,
    /// whose files it vouches for.
    case scans
    /// The paths the user removed from the library, which scans skip (ADR 0050). Keyed by path
    /// ID, and a part of its own for the same reason as `loved`.
    case removed
    /// The paths with a row in `history`, which History lists (ADR 0057). Derived from
    /// `history`, so building the part fills it from there, and rebuilding it discards nothing.
    case recorded
    /// The lines of the Problems window the user dismissed (ADR 0059). A part of its own for
    /// the same reason as `loved`.
    case dismissed

    var sql: String {
        switch self {
        case .index: indexSchema
        case .stats: statsSchema
        case .loved: lovedSchema
        case .disliked: dislikedSchema
        case .imports: importsSchema
        case .importedLastPlays: importedLastPlaysSchema
        case .sync: syncSchema
        case .scans: scansSchema
        case .removed: removedSchema
        case .recorded: recordedSchema
        case .dismissed: dismissedSchema
        }
    }

    /// What takes the part's data out of the stats before its earlier tables are dropped, in a
    /// rebuild that keeps the stats; nil for a part whose rows the stats don't count.
    var discardSQL: String? {
        self == .imports ? importsDiscardSQL : nil
    }

    /// The tables the part creates; nil for the index, which is every table no other part names.
    var tables: Set<String>? {
        switch self {
        case .index: nil
        case .stats: statsTables
        case .loved: [lovedTable]
        case .disliked: [dislikedTable]
        case .imports: [importedPlaysTable]
        case .importedLastPlays: [importedLastPlaysTable]
        case .sync: syncTables
        case .scans: [scannedFoldersTable]
        case .removed: [removedTable]
        case .recorded: [recordedTable]
        case .dismissed: [dismissedProblemsTable]
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
    "paths", "plays", "ratings", "history", "playlists", "playlist_entries", shareRootsTable,
]

let lovedTable = "loved"
let dislikedTable = "disliked"
let scannedFoldersTable = "scanned_folders"
let removedTable = "removed"
let recordedTable = "recorded_paths"
let dismissedProblemsTable = "dismissed_problems"
let shareRootsTable = "share_roots"
let importedPlaysTable = "imported_plays"
let importedLastPlaysTable = "imported_last_plays"
let syncStateTable = "sync_state"
let syncOutboxTable = "sync_outbox"
let syncLogsTable = "sync_logs"
let syncItemsTable = "sync_items"
let syncPlaylistsTable = "sync_playlists"
let syncMovesTable = "sync_moves"
let syncTables: Set<String> = [
    syncStateTable, syncOutboxTable, syncLogsTable, syncItemsTable, syncPlaylistsTable,
    syncMovesTable,
]

private let indexSchema = """
    CREATE TABLE files (
        -- The path's ID in paths, which an index rebuild keeps.
        id INTEGER PRIMARY KEY REFERENCES paths (id),
        path TEXT NOT NULL UNIQUE,
        -- Where the file name starts in path, in characters from 1, as substr counts them.
        name_offset INTEGER NOT NULL,
        size_bytes INTEGER NOT NULL,
        -- Seconds since 1970, compared exactly with the walk's value to skip unchanged files.
        modified_seconds REAL NOT NULL,
        -- Seconds since 1970, from the walk; NULL when the volume doesn't say.
        created_seconds REAL,
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
        -- The artist the Artist pane lists the track under when grouping by album artist: the
        -- album artist, else Various Artists for a compilation, else the track artist.
        group_artist_id INTEGER REFERENCES artists (id),
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
        grouping TEXT,
        catalog_number TEXT,
        barcode TEXT,
        bpm INTEGER,
        musical_key TEXT,
        conductor TEXT,
        lyricist TEXT,
        publisher TEXT,
        copyright TEXT,
        encoder TEXT,
        description TEXT,
        disc_subtitle TEXT,
        work TEXT,
        movement_number INTEGER,
        movement_name TEXT,
        original_date TEXT,
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
    CREATE INDEX tracks_genre_group_artist ON tracks (genre_id, group_artist_id);
    CREATE INDEX tracks_group_artist_album ON tracks (group_artist_id, album_id);
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
        -- In NFC, so a name listed decomposed once and precomposed later is one path (ADR
        -- 0026). files.path keeps the spelling the volume listed, which opens the file.
        path TEXT NOT NULL UNIQUE,
        -- When the path was first seen, in seconds since 1970: the "date added" column.
        added_seconds REAL NOT NULL,
        -- What the last read of the file found, to match it with a new path once it's gone
        -- and can't be read (ADR 0026). NULL until a read succeeds; the title is in NFC.
        codec TEXT,
        sample_rate_hz INTEGER,
        length_frames INTEGER,
        title TEXT,
        -- 1 once the user dismissed the path from Lost Stats; a read of its file clears it.
        lost_dismissed INTEGER NOT NULL DEFAULT 0
    );
    -- Move matching and Lost Stats look paths up by length.
    CREATE INDEX paths_length ON paths (length_frames);
    -- Where the paths of each watched folder on a share were last (ADR 0028), so a new mount
    -- point rewrites them.
    CREATE TABLE \(shareRootsTable) (
        share TEXT NOT NULL,
        -- The folder's path inside the share, as configured.
        inner_path TEXT NOT NULL,
        -- In canonicalPath's form, as files.path starts.
        root TEXT NOT NULL,
        PRIMARY KEY (share, inner_path)
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
    -- Move matching asks whether a path is in any playlist.
    CREATE INDEX playlist_entries_path ON playlist_entries (path_id);
    """

private let scansSchema = """
    -- Each watched folder whose last whole scan finished, by its root in canonicalPath's form.
    -- A whole scan deletes its folder's row as it starts, so one cut short leaves none.
    CREATE TABLE \(scannedFoldersTable) (
        root TEXT PRIMARY KEY
    );
    """

private let removedSchema = """
    -- A row for each path removed from the library; its file isn't indexed until it's restored.
    CREATE TABLE \(removedTable) (
        path_id INTEGER PRIMARY KEY REFERENCES paths (id)
    );
    """

private let recordedSchema = """
    -- A row for each path with a row in history. History tests this instead of history_path,
    -- whose million rows cost a slow lookup per played track.
    CREATE TABLE \(recordedTable) (
        path_id INTEGER PRIMARY KEY REFERENCES paths (id)
    );
    \(fillRecordedSQL);
    """

/// Adds the paths with a row in `history` to `recordedTable`, for a fill from scratch.
package let fillRecordedSQL =
    "INSERT OR IGNORE INTO \(recordedTable) (path_id) SELECT DISTINCT path_id FROM history"

private let dismissedSchema = """
    -- A row for each line of the Problems window the user dismissed, as the window showed it.
    CREATE TABLE \(dismissedProblemsTable) (
        line TEXT PRIMARY KEY
    ) WITHOUT ROWID;
    """

private let lovedSchema = """
    -- A row for each loved path; none means not loved.
    CREATE TABLE \(lovedTable) (
        path_id INTEGER PRIMARY KEY REFERENCES paths (id)
    );
    """

private let dislikedSchema = """
    -- A row for each disliked path; none means not disliked.
    CREATE TABLE \(dislikedTable) (
        path_id INTEGER PRIMARY KEY REFERENCES paths (id)
    );
    """

private let importsSchema = """
    -- Each player's play and skip totals for a path, the highest any machine's import reported;
    -- an import here or synced adds what passes them. Changing this SQL rebuilds the part, which
    -- takes the imports' plays and skips out of the counts first (importsDiscardSQL), so the
    -- owner imports again after it.
    CREATE TABLE \(importedPlaysTable) (
        player TEXT NOT NULL,
        path_id INTEGER NOT NULL REFERENCES paths (id),
        play_count INTEGER NOT NULL,
        skip_count INTEGER NOT NULL,
        PRIMARY KEY (player, path_id)
    );
    """

/// Takes the imports' plays and skips out of the counts before `imported_plays` is dropped, or
/// the next import would add them again. Each play count becomes its history, the plays recorded
/// here and synced; skips have no history, so each loses the skips the imports recorded.
private let importsDiscardSQL = """
    UPDATE plays SET
        play_count = (SELECT count(*) FROM history h WHERE h.path_id = plays.path_id),
        skip_count = max(0, skip_count - (SELECT ifnull(sum(i.skip_count), 0)
            FROM \(importedPlaysTable) i WHERE i.path_id = plays.path_id));
    """

private let importedLastPlaysSchema = """
    -- Each player's last play of a path, as its imports gave it, in whole seconds since 1970.
    CREATE TABLE \(importedLastPlaysTable) (
        path_id INTEGER NOT NULL REFERENCES paths (id),
        player TEXT NOT NULL,
        played_at INTEGER NOT NULL,
        PRIMARY KEY (path_id, player)
    );
    -- Filled, as the table is made, from the import counts and Last Played: a path's Last
    -- Played where one player's import alone counted plays for it and no history row is at or
    -- after it, so the time is that import's and not a real play's.
    INSERT INTO \(importedLastPlaysTable) (path_id, player, played_at)
    SELECT i.path_id, i.player, CAST(p.last_played_seconds AS INTEGER)
    FROM \(importedPlaysTable) i JOIN plays p ON p.path_id = i.path_id
    WHERE i.play_count > 0 AND p.last_played_seconds IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM \(importedPlaysTable) o
            WHERE o.path_id = i.path_id AND o.player != i.player AND o.play_count > 0)
        AND NOT EXISTS (SELECT 1 FROM history h
            WHERE h.path_id = i.path_id AND h.played_at >= CAST(p.last_played_seconds AS INTEGER));
    """

/// Each import's last play of a path that the import counted plays for, as `path_id` and
/// `played_at`: one dated play of the import's, which Listening Stats counts with the history
/// (ADR 0105). The rest of its plays have no date.
let importedLastPlaysSQL = """
    SELECT d.path_id, d.played_at FROM \(importedLastPlaysTable) d
    JOIN \(importedPlaysTable) i ON i.path_id = d.path_id AND i.player = d.player
    WHERE i.play_count > 0
    """

private let syncSchema = """
    -- This machine: its ID, minted here so it lives as long as its log's sequence numbers; its
    -- clock; its log's size; and how much of the log reached the sync folder, which is named
    -- so another folder gets the log from the start.
    CREATE TABLE \(syncStateTable) (
        one INTEGER PRIMARY KEY CHECK (one = 1),
        machine TEXT NOT NULL,
        clock_ms INTEGER NOT NULL,
        clock_n INTEGER NOT NULL,
        log_bytes INTEGER NOT NULL,
        -- 1 once the log reached a cap, after which nothing more is logged.
        full INTEGER NOT NULL,
        pushed_folder TEXT,
        pushed_seq INTEGER NOT NULL,
        pushed_bytes INTEGER NOT NULL
    );
    INSERT INTO \(syncStateTable) VALUES (1, lower(hex(randomblob(16))), 0, 0, 0, 0, NULL, 0, 0);
    -- This machine's log, one line a row, each written in the transaction of its change.
    CREATE TABLE \(syncOutboxTable) (
        seq INTEGER PRIMARY KEY,
        line TEXT NOT NULL
    );
    -- How far each other machine's log was read and applied: the byte offset in the file as
    -- it was in the folder named, the last sequence number applied and the lines read; and
    -- the event waiting for its playlist's create, and for how many syncs.
    CREATE TABLE \(syncLogsTable) (
        machine TEXT PRIMARY KEY,
        folder TEXT NOT NULL,
        offset INTEGER NOT NULL,
        seq INTEGER NOT NULL,
        lines INTEGER NOT NULL,
        waiting_seq INTEGER NOT NULL,
        waiting_syncs INTEGER NOT NULL
    );
    -- The change each synced field holds: a rating or love by path ID, a playlist's name,
    -- rules or entries by playlist ID. Last writer wins against it.
    CREATE TABLE \(syncItemsTable) (
        item TEXT NOT NULL,
        key INTEGER NOT NULL,
        ms INTEGER NOT NULL,
        n INTEGER NOT NULL,
        machine TEXT NOT NULL,
        PRIMARY KEY (item, key)
    );
    -- Each synced playlist's ID in the logs; a deleted one keeps its row with no playlist, so
    -- a late create doesn't bring it back.
    -- Each move made or read, by sync path, so an event for the old path read later goes to
    -- the new one.
    CREATE TABLE \(syncMovesTable) (
        from_path TEXT PRIMARY KEY,
        to_path TEXT NOT NULL
    );
    CREATE TABLE \(syncPlaylistsTable) (
        id TEXT PRIMARY KEY,
        playlist_id INTEGER UNIQUE REFERENCES playlists (id) ON DELETE SET NULL
    );
    """
