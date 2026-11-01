# 0033. Importing from Swinsian and iTunes: matched by path, merged per field, counted once

- **Date:** 2026-11-01
- **Status:** accepted
- **Amends:** [0018](0018-playlists-and-stats.md), [0022](0022-stable-track-identity-and-play-timeline.md),
  [0025](0025-threat-model.md), [0032](0032-playlist-files.md)

## Context

Phase 18 brings plays, ratings, dates, loved tracks and playlists across from the player the
owner used before: Swinsian, whose library is a SQLite database in
`~/Library/Application Support/Swinsian/`, or iTunes and Music, which export `Library.xml`.
Both files come from other programs and are hostile input (0025). Neither player's track IDs
mean anything here, and Swinsian's bookmarks resolve only on the Mac that made them, so tracks
match by path. The owner's Swinsian library holds one path in more than one row. No Swinsian
database exists on the Mac this was built on, so its schema below is assumed, not read.

## Decision

### Reading

- **Swinsian.** Import from Swinsian… opens a panel in Swinsian's folder. The database file the
  owner picks, and its `-wal` when there is one, are copied into a new folder in the user's
  temporary folder through `FileSource` (`O_NOFOLLOW`, a regular file only), 4 GiB at most
  together. Each is `lstat`ed before and after; a change in size, modification time or inode
  means Swinsian wrote during the copy, and the import stops and asks for Swinsian to be quit.
  The copy is opened with `SQLITE_OPEN_READONLY`, `query_only` and `trusted_schema = OFF`, so
  its WAL is read and its schema can't call functions as it's read; the live file, its WAL and
  its shared memory are never opened by SQLite. The copy is deleted when the read ends.
- **The schema is checked before it's read.** Every table and column below is looked up in
  `sqlite_master` and `PRAGMA table_info`. Any missing fails the whole import with one error
  naming each missing table and column, rather than guessing at another name. Each value's
  storage class is checked too: a count must be an integer, a date a number, a path text. A
  value of the wrong type is a typed problem for that row, which is then left out or keeps that
  field empty, never read as 0.
- **iTunes and Music.** `Library.xml`, 256 MiB at most, read through `FileSource` and parsed by
  `PropertyListSerialization`. It holds dozens of keys per track; only the ones below are read,
  and the rest are ignored, since another build of Music adds keys this one doesn't need. A key
  it reads with the wrong type is a typed problem. `Location` is a `file:` URL decoded by phase
  17's code (0032): only `file` with no host or `localhost`, `%` escapes as UTF-8.
- **Caps.** 1,000,000 tracks, 10,000 playlists, 2,000,000 playlist entries in all, 100 rules a
  playlist, 4 KiB a path, 1 KiB a playlist name. Past a cap the rest isn't read and the problem
  says so. Problems list 100, then a count.

### The Swinsian schema assumed (unverified)

| Table | Column | Read as |
|---|---|---|
| `track` | `track_id` | integer, the row's ID |
| | `path` | text, a POSIX path |
| | `playcount` | integer, 0 or more |
| | `lastplayed` | number, seconds since 2001-01-01 UTC, or NULL |
| | `dateadded` | number, seconds since 2001-01-01 UTC, or NULL |
| | `rating` | integer, 0 to 5 stars |
| | `loved` | integer, 0 or 1 |
| `playlist` | `playlist_id` | integer |
| | `name` | text |
| | `smart` | integer, 1 for a smart playlist |
| | `matchall` | integer, 1 when every rule must hold, 0 for any |
| `playlisttrack` | `playlist_id`, `track_id` | integers |
| | `position` | integer, the order |
| `smartrule` | `playlist_id`, `position` | integers |
| | `field`, `operator` | text, below |
| | `value` | text, or a number |

A rule's `field` and `operator` are assumed to be this app's own field and comparison names
(`SmartField`, `SmartComparison`) ignoring case, such as `playcount` and `greaterthan`, with
dates compared in days and ratings in stars; any other name, a value of the wrong kind, or a
rule our editor would refuse leaves the playlist unmapped. Swinsian limits, if it has them,
aren't read. Every value is read by its SQLite storage class, not its declared type.

A date before 1970 or more than a day in the future is a problem for that field and is left out,
so a wrong epoch shows in the preview as a problem on every dated track instead of moving every
date. A rating over 5 is a problem the same way, so a 0–100 scale shows instead of reading as
5 stars. The checkpoint's command prints the real schema and each table's row count, without any
rows, so the next session can correct this table.

### iTunes keys read

`Location`, `Play Count`, `Skip Count`, `Play Date UTC`, `Date Added`, `Rating` (0–100, a star
each 20, ignored with `Rating Computed`, which is an album's rating shown on its tracks),
`Loved` and `Favorited`. Playlists: `Name`, `Playlist Items` of `Track ID`, `Smart Info`. The
master playlist, playlists with a `Distinguished Kind` (Music, Movies, Podcasts…) and folders
are built in or hold other playlists, so they're skipped and counted.

### Matching

- **By path.** One optional prefix replacement first, the whole prefix replaced only at a
  folder boundary. Then phase 17's lookup (0032): as written, then in NFC. Only tracks the
  index holds get anything; unmatched paths are counted and listed. Nothing is added to `paths`
  for them, as 0032 decided for playlist files.
- **Rows for one path merge** before matching, compared in NFC: plays and skips add, last played
  takes the latest, date added the earliest, rating the highest, and loved holds if any row is.
  The preview counts the rows merged. Two source paths that reach one track merge the same way.

### Merging

| Field | Rule |
|---|---|
| Plays, skips | ours plus what the source has gained since its last import of that track |
| Last played | the later of ours and theirs |
| Date added | the earlier of ours (`paths.added_seconds`) and theirs |
| Rating | theirs, only where we have none and theirs is 1 to 5 stars |
| Loved | loved when theirs is; never unloved |
| Playlists | a new playlist per source playlist, unless one of that name exists (compared in NFC, ignoring case), which is skipped and listed |

- **Plays add no history rows.** The other player kept no date for each play, and the timeline
  lists real plays only. Last played is set, so History (one row a track) lists them.
- **A second import adds nothing new.** A schema part of its own, `imports`, keeps each player's
  imported play and skip counts per path ID (`imported_plays`). An import adds the difference
  from those, never less than 0, and records the new ones; every other rule is a maximum, a
  minimum, a union or "only where none", and a playlist of the same name is skipped, so running
  the same import again changes nothing, and running a newer Swinsian library adds only the plays
  since. Keyed by player, not by file, so a fresh copy of the same library counts as the same.
  A separate part keeps a change to it from discarding the stats (0031).
- **Preview, then one transaction.** The preview reads the library and computes the plan without
  writing. Confirming recomputes it inside one transaction from the same code and writes it all,
  so a scan or a play in between is counted, not overwritten. The report shows what was written.
- **Playlists.** Manual ones take their matched tracks in order, each once (0018); missing and
  repeated entries are counted. A Swinsian smart playlist whose every rule maps becomes a smart
  playlist; one with any rule that doesn't is not imported, and the report lists it with each
  rule that didn't map. An iTunes smart playlist's rules are a private binary format, so it
  becomes a manual playlist of the tracks the file lists for it, and the report says so.

## Alternatives considered

- **Refusing a second import by the file's hash.** Rejected: the owner may keep using Swinsian
  for a while, and a newer copy hashes differently, so its plays would double; a refusal would
  also stop a deliberate re-run after fixing the prefix.
- **Opening the live database read-only or with `immutable=1`.** Rejected: read-only still maps
  Swinsian's shared memory and takes its locks, and `immutable` skips the WAL, so recent plays
  would be missing.
- **Guessing Swinsian's column names from what's there.** Rejected: a near match is a wrong
  number in the owner's stats with nothing to show for it. The check names what's missing.
- **Adding the imported plays to the timeline** at the last played time. Rejected: one play would
  stand for many, dated wrong.
- **Merging into a playlist that exists by name.** Rejected: it would add another player's tracks
  to a playlist the owner made here; skipping and listing is reversible by renaming.

## Consequences

Until the checkpoint's schema comes back, a Swinsian import may stop on a missing column and say
which. A track moved since the other player last saw it is listed as unmatched. Removing an
import's plays means editing the database; there is no undo beyond not confirming.
