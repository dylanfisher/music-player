# 0038. Machines share stats through one append-only log each in a sync folder

- **Date:** 2026-11-01
- **Status:** accepted
- **Amends:** [0022](0022-stable-track-identity-and-play-timeline.md),
  [0025](0025-threat-model.md), [0026](0026-sync-identity-is-the-relative-path.md),
  [0028](0028-network-folders-by-share.md), [0033](0033-import-from-other-players.md)

## Context

Phase 23 has two or three Macs play the same NAS library, each with its own index, and share
plays, skips, ratings, loved tracks, playlists and Date Added. SMB has no locking the app can
rely on, the NAS comes and goes, a Mac's clock can be wrong, and any of the machines can be
off for weeks. 0026 made a track's identity its path relative to the library root, and 0028
stored network folders by share. Until now the app wrote nothing outside its data folder and
the config file but music files, through the tag writer.

## Decision

### The folder and the boundary

- `sync.folder` in the config file, null by default: `{"path": "/Users/me/Sync"}`, or on a
  share `{"share": "smb://nas/music", "path": "sync"}`, found the way 0028 finds a watched
  folder. The config check refuses one inside or equal to a watched folder stored the same
  way; the watcher checks the located paths again before every sync, for a folder stored by
  share against one stored by path. Settings shows it with Choose… and Clear; a folder picked
  on a share is stored by share.
- The app writes one file there, `<machine id>.log`, and nothing else: no temporary file, no
  lock file, no rename. It never writes another machine's log. AGENTS.md says so.

### Identity

- **A sync path** is the share's name in lowercase, the watched folder's path inside the share
  and the path under the folder, in NFC: `music/library/Artist/Album/01.flac`. The share's
  name rather than the folder is the root, since two Macs can watch different folders of one
  share, and the name, unlike the host, is the same on every Mac (0028). Only folders stored by
  share are synced; local folders hold different files on each Mac. Each machine maps a sync
  path to its own `paths` row through `share_roots`, so every machine can mount the share
  anywhere.
- **The machine ID** is 32 random hex digits, minted by the SQL that creates the database's
  `sync` part and kept in `sync_state` beside the log it names, not in the state file. The ID
  has to live exactly as long as the log's sequence numbers: the state file is discarded whole
  when it doesn't match the schema, and a lost ID with the log carrying on would publish the
  same events under a second name, which every other machine would count again. A database
  started over gets a new ID, so a new log, and never collides with its old one.
- **An event's identity** is its machine and its sequence number in that machine's log, which
  starts at 1 and only grows.

### The log

- **One event a line**, a JSON object ending in `\n`: `seq`, the clock as `ms` and `n`, `event`,
  and the event's own keys, all required, nothing else:

  | `event` | keys |
  |---|---|
  | `play` | `path`, `at` (seconds since 1970) |
  | `skip` | `path` |
  | `counts` | `path`, `plays`, `skips`, `lastPlayed` (a time or null): an import's counts |
  | `rating` | `path`, `stars` (0 clears) |
  | `loved` | `path`, `loved` |
  | `added` | `path`, `at`: Date Added |
  | `move` | `from`, `to` |
  | `playlistCreate` | `playlist` (32 hex digits), `name`, `rules` (a smart playlist's JSON or null) |
  | `playlistRename` | `playlist`, `name` |
  | `playlistRules` | `playlist`, `rules` |
  | `playlistEntries` | `playlist`, `paths`: the whole list, in order |
  | `playlistDelete` | `playlist` |

- **The local copy is the `sync_outbox` table**, one row a line, in the library database in
  the data folder. Every change writes its event in the same transaction, so the event is
  stored exactly when the change is, by any connection: the window, the scanner and
  `--scan`. That costs one insert and one small update, whatever the log's size.
- **Pushing** appends the outbox's tail to the folder's `<id>.log`, which is always a byte
  prefix of the outbox. The file is opened in the folder's descriptor with `O_NOFOLLOW` and
  `O_APPEND` and must be a regular file of this user with one link. Its size says how much
  arrived; bytes past what `sync_state` recorded (a push that died before recording) must be
  the outbox's next bytes, so the push continues from there, even mid-line. A file shorter
  than recorded, or one that doesn't match, isn't written and is reported, and the other logs
  are still read: some other process wrote it. To start it again the owner moves the log out
  of the folder, which the report says; an empty log gets the whole outbox, as a new folder
  does, and the other machines read it again from the start without counting twice. A lock
  file beside the database, held with `flock` for the whole push, keeps a second copy of the
  app from pushing at the same time; that copy reports it and waits.
- **Caps**, shared by the writer and every reader: 4 MiB a line, 100,000 entries a playlist
  event, 1 GiB and 4,000,000 events a log. A sync adds at most 500,000 `paths` rows, leaving
  the rest of the logs for the next, and keeps at most 100,000 looked-up paths in memory. A log at a cap takes no more events and says so once in the window's notices; a
  playlist whose list doesn't fit a line isn't synced, also with a notice. A million plays are
  about 110 MB.

### The clock

- **A hybrid logical clock:** the wall time in milliseconds and a counter. Each event takes
  the later of the machine's last clock and its wall clock, adding one to the counter when the
  last is later. An edit of a rating, a love or a playlist field takes a clock after the one
  that field holds too, so an edit made after seeing a value always replaces it, however far
  off the clock that wrote the value was.
- **Skew bound, one hour.** Taking a field's clock moves the machine's own clock forward at
  most one hour past its wall time. Past that only that field's edits go after it, so a Mac
  whose clock is a year ahead wins the conflicts it's part of, but can't drag the other
  machines' clocks into next year and win every later one. A log whose clocks run more than an
  hour ahead of the reader's is reported once per read.
- Ties break on the machine ID, so every machine picks the same winner.

### Merging

- **When:** at the watcher's start, after each scan (network folders are polled), on wake, a
  network change and a mount (0028's triggers), and a push alone after each edit in the window.
  Nothing polls for sync. A sync runs on the scan queue, so never beside a scan, and waits, as
  network scans do, while playback holds them back. A share that isn't mounted skips it; the
  events wait in the outbox.
- **Reading:** every `<32 hex digits>.log` but this machine's, up to 64, each opened with
  `O_NOFOLLOW` in the folder's descriptor and checked by `fstat` as a regular file. Each is read
  from where the last read stopped to its last complete line: a line without its `\n` is left
  for the next read. The logs are merged in clock order, so a playlist's creation comes before
  its rename from another machine, and applied in transactions of 20,000 events (a playlist's list counting one per entry), each storing
  how far it read every log (`sync_logs`), so a crash repeats nothing. A log shorter than where
  reading stopped, or where that offset no longer ends a line, was replaced: it's read again
  from the start and reported; its sequence numbers keep events
  already applied from counting twice.
- **Plays and skips** are a union: each event applies once, by its sequence number. A play
  adds a history row and a play, and keeps the latest Last Played. Merged plays join the
  timeline as they arrive, so the timeline is in the order this machine learned of them.
- **Ratings, loved, playlist names, rules and entries:** the latest clock wins, then the
  higher machine ID. `sync_items` holds the clock of the change each field holds. A value set
  before this build has no clock and loses to any event.
- **A playlist's entries are one value**, the whole list: an edit on two machines at once
  keeps one machine's list. Per entry it would need an order that merges, for a playlist the
  owner edits on one Mac at a time.
- **A playlist's create stamps all its fields**, so the first edit of its name, rules or
  entries on another machine comes after it in clock order, however that machine's clock runs.
  An edit read before its create (the creator's log couldn't be opened this time, or a far-off
  clock put the create later) waits, holding its log there, until another event is applied in
  the same sync, or the next sync; after 10 syncs it's skipped and reported.
- **A playlist's create stamps all its fields**, so the first edit of its name, rules or
  entries on another machine comes after it in clock order, however that machine's clock runs.
  An edit read before its create (the creator's log couldn't be opened this time, or a far-off
  clock put the create later) waits, holding its log there, until another event is applied in
  the same sync, or the next sync; after 10 syncs it's skipped and reported.
- **Deleting a playlist wins** over any change to it, earlier or later, and its ID is kept as a
  tombstone so a late create doesn't bring it back.
- **Date Added** is the earliest any machine saw. A new path's `added` event comes from its
  first scan on each machine.
- **Moves** (0026): a machine without a row for the old path, or that made the move itself,
  ignores it. One with a row for the old path and none for the new gives the old row the new
  path. One with both merges the new path's stats into the old row by the rules above, plays
  and skips added, history moved, and then makes the move: a move arriving after the new path
  was played. Where both paths have a file in this index, the move is skipped and reported.
- **A path this machine has no row for** but under one of its share folders gets a row, as a
  play of a file never scanned does (0022): the stats wait there for the scan to find the
  file. A path under none of its share folders is skipped, and the count reported: a Mac that
  doesn't watch that folder doesn't keep its stats.
- **The import** (0033) runs on one machine and writes events for what it changed: `counts`
  for the plays and skips it added, `rating`, `loved`, `added` and each playlist.
- **Nothing from before this build is sent.** The log starts with this build, and a playlist
  made before it is sent whole at its next change.

### Problems

Every log is hostile input (0025 rows 51 to 55). A line that doesn't decode, a sequence number
that doesn't grow, an unknown playlist and the like are each a problem, kept per log up to 100
and then counted, shown in the window's problems list. The rest of the log carries on.

## Alternatives considered

- **One shared database or file on the NAS** — rejected: two writers over SMB need locking it
  doesn't give.
- **Syncing the index** — rejected: each machine scans the same files; only what no scan can
  recreate is shared.
- **Wall clock timestamps** — rejected: a Mac with a wrong clock would win every conflict.
- **An unbounded hybrid clock** — rejected: one far-off clock would carry every machine's
  clock with it.
- **A local log file beside the database** — rejected: the event would be written outside
  the change's transaction, and the window, the scanner and `--scan` would need to share
  sequence numbers through a lock.
- **The machine ID in the state file**, as the plan said — rejected for the reason under
  Identity.
- **Per-entry playlist merging** — rejected above.
- **Rejecting or holding back events past the skew bound** — rejected: holding back stalls a
  log until the clocks agree, and rejecting splits the machines for good.
- **Sending every existing stat at the first sync** — rejected: plays from before this build
  are counts and history rows with no identity, so a second machine sending its own copy would
  count them twice. The owner's stats were reset by 0026's schema change anyway.

## Consequences

Every machine converges on the same plays, ratings, loved tracks, playlists and Date Added
once it has read every log, whatever order it reads them in. Logs only grow, about 110 bytes a
play; at a cap a machine stops sharing and says so. A playlist edited on two Macs at once keeps
one edit. A machine that doesn't watch a folder never gets its stats, even if it adds the
folder later. A library database started over, or a rebuild of its stats, starts a new log
under a new ID and reads every log from the start, its own old one included, which restores
what the folder holds.
