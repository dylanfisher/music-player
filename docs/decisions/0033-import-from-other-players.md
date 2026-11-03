# 0033. Importing from Swinsian and iTunes: matched by path, merged per field, counted once

- **Date:** 2026-11-01
- **Status:** accepted
- **Amended by:** [0057](0057-history-lists-recorded-plays.md): History leaves out imported
  plays, which add no history rows.
- **Amends:** [0018](0018-playlists-and-stats.md), [0022](0022-stable-track-identity-and-play-timeline.md),
  [0025](0025-threat-model.md), [0032](0032-playlist-files.md)
- **Amended by:** [0059](0059-problems-window-actions.md): a miss in a format the scanner
  skips is listed apart, and Locate… matches the misses again under another folder.
  [0061](0061-swinsian-column-layout.md): the Swinsian import can bring across its column
  layout, from its preferences file.

## Context

Phase 18 brings plays, ratings, dates, loved tracks and playlists across from the player the
owner used before: Swinsian, whose library is a SQLite database in
`~/Library/Application Support/Swinsian/`, or iTunes and Music, which export `Library.xml`.
Both files come from other programs and are hostile input (0025). Neither player's track IDs
mean anything here, and Swinsian's bookmarks resolve only on the Mac that made them, so tracks
match by path. The owner's Swinsian library holds one path in more than one row (32 extra rows
in 43,400). Its schema below was read from the owner's library on 2026-11-01: the tables, their
columns, row counts and value ranges, no rows.

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
  says so. Problems list 100, then a count. A Swinsian rule archive is 64 KiB, 2,048 objects
  and 64 references deep at most, and a playlist lists 10 reasons, then a count.

### The Swinsian schema read

| Table | Column | Read as |
|---|---|---|
| `track` | `track_id` | integer, the row's ID |
| | `path` | text, an absolute POSIX path, such as `/Volumes/music/library/…` |
| | `playcount` | integer, 0 or more |
| | `lastplayed` | number, seconds since 2001-01-01 UTC; 0 or NULL is never |
| | `dateadded` | number, seconds since 2001-01-01 UTC, or NULL |
| | `rating` | stars, 0 to 5 in half steps, stored as REAL in an INTEGER column, or NULL |
| | `favourite` | integer, 1 for loved, 0 or NULL for not |
| `playlist` | `playlist_id`, `name` | integer, text |
| | `smart` | integer, 1 for a smart playlist |
| | `smartpredicate` | blob, the rules: an `NSPredicate` archived by `NSKeyedArchiver` |
| | `folder` | integer, 1 for a folder, which is skipped and counted as built in |
| | `limited` | integer, 1 for a playlist limited to some of its tracks |
| `playlisttrack` | `playlist_id`, `track_id` | integers |
| | `tindex` | integer, the order |

`playlistfolderplaylist` says which folder holds a playlist. Folders flatten here, so it isn't
read. Every value is read by its SQLite storage class, not its declared type: a whole rating of
REAL affinity in an INTEGER column reads as an integer, and a half one as a real.

**Ratings.** Ours are whole stars. A half star rounds up, 0.5 to 1 and 4.5 to 5, as iTunes's
0–100 ratings already do (a star each 20, rounded). The preview counts the ratings that came
from a half star. Rows for one path keep the highest rating, which counts as rounded only when
every row with that rating was.

**Smart playlists.** `smartpredicate` is never given to `NSKeyedUnarchiver`: for a malformed
comparison or function expression, `NSPredicate` raises `NSInvalidUnarchiveOperationException`
even under `.setErrorAndReturn`, and Swift can't catch it, so one bad archive would end the
app. The fuzzer found five in 120 s. Instead the archive is read with
`PropertyListSerialization` and its object table walked by `SwinsianArchive`, which reads only
`NSCompoundPredicate` (type and subpredicates), `NSComparisonPredicate` (left, right, operator
type, options, modifier), `NSKeyPathExpression` and `NSKeyPathSpecifierExpression` (the key
path), `NSConstantValueExpression` (a string or number) and `NSFunctionExpression` (the
`now()` minus N shape with its CASTs). Any other class or shape is an unsupported rule, listed.
First the archive's keys are checked, then its size (64 KiB), its objects (2,048) and its
references: every one in range, no cycle, 64 deep at most, which also bounds the reader's
recursion. At most 4,096 parts are read, since one object can be listed many times at each level, and a string is 10,000 bytes at most. Nothing is evaluated, and the `predicateFormat`
text isn't parsed; a reason quotes the rule as the reader rebuilds it, 200 characters at most.

| Swinsian | Here |
|---|---|
| `genre`, `fileType` with `BEGINSWITH[c]`, `CONTAINS[c]`, `==[c]` | starts with, contains, is |
| `NOT` of `CONTAINS[c]`, `==[c]` | doesn't contain, is not |
| `sampleRate`, `bitRate` with `>`, `==` (and `NOT ==`) | greater than, is (is not); hertz and kilobits a second, as ours |
| `groupingLength > 0` (and its `NOT`) | grouping is not "" (is "") |
| `dateAdded`, `lastPlayed` `> CAST(CAST(now(), "NSNumber") - N, "NSDate")` | in the last N / 86,400 days (not in the last, for its `NOT`) |
| `AND`, `OR` | all, any |
| `NOT` of `AND` or `OR` | pushed to the comparisons by De Morgan: `NOT (a OR b)` is `NOT a AND NOT b` |

Anything else leaves the playlist unmapped and listed with why: a comparison without `[c]`
(ours ignore case), any other key or operator, a `NOT` of `BEGINSWITH` or `>`, a fixed date, a
time that isn't whole days, all and any mixed in one playlist, `ANY` or `ALL`, and a rule our
editor would refuse. A limited playlist is listed too, since its limit isn't read and it would
otherwise come across with more tracks than it holds. The owner's 18 smart playlists all map.
Swinsian's `bitRate > 1000` compares the `bitrate` column, in kilobits a second as ours, which
is the average over the file. Our file type is the extension. Swinsian's `"dsd"` is assumed to
mean DSDIFF, whose files are `.dff`, so it maps to `dff`; `"dsf"` is `.dsf` in both. This is
unverified until the owner's DSD playlist is checked after the import.

A date before 1970 or more than a day in the future is a problem for that field and is left out.
A rating past 5 or between half steps is a problem the same way.

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
  the same import again changes nothing, and running a newer Swinsian library adds only the
  plays since. The baseline is per player, not per source file: a fresh copy of the same library
  counts as the same, and so do two different Swinsian databases or two different XML exports,
  which share one baseline, so the second adds only plays past the first's count for each track.
  A separate part keeps a change to it from discarding the stats (0031).
- **The preview sheet** shows only the current plan: a preview that fails clears the counts and
  keeps Import off until one succeeds.
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
- **Parsing the rules' `predicateFormat` text, or evaluating the predicate** against a track.
  Rejected: the text has no grammar of its own to rely on, and evaluating would run whatever
  the archive asks for; the archive's structure says exactly what each part is.
- **Decoding with `NSKeyedUnarchiver` under secure coding**, with an allowed-class list.
  Rejected: `NSPredicate` raises an Objective-C exception for a malformed archive, which ends
  the app; catching it would need an Objective-C target in a Swift and C tree.
- **Half stars rounded down, or kept as halves.** Rejected: rounding down makes 0.5 unrated,
  and halves would change the rating column, the editor and smart rules for one import.
- **Guessing Swinsian's column names from what's there.** Rejected: a near match is a wrong
  number in the owner's stats with nothing to show for it. The check names what's missing.
- **Adding the imported plays to the timeline** at the last played time. Rejected: one play would
  stand for many, dated wrong.
- **Merging into a playlist that exists by name.** Rejected: it would add another player's tracks
  to a playlist the owner made here; skipping and listing is reversible by renaming.

## Consequences

A Swinsian that changes its schema makes the import stop on the missing column and say which. A track moved since the other player last saw it is listed as unmatched. Removing an
import's plays means editing the database; there is no undo beyond not confirming.
