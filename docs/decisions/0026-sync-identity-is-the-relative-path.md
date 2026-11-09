# 0026. Sync identifies a track by its path relative to the library root, and scans detect moves

- **Date:** 2026-11-01
- **Status:** accepted
- **Amends:** [0022](0022-stable-track-identity-and-play-timeline.md)
- **Amended:** 2026-11-07 (lossless codecs match each other; a move list is a second source of
  moves)
- **Amended by:** [0154](0154-a-move-needs-more-than-a-length.md): audio facts alone never
  match; a move also needs the same path but for the extension, or the same title.

## Context

Phase 23 shares plays, ratings, playlists and Date Added between two or three Macs. Every
machine plays the same files on the same NAS, but mounts it at its own path: `/Volumes/music`
on one Mac can be `/Volumes/music-1` on another. Locally, 0022 keys stats on a permanent ID per
absolute path, so a renamed or moved file loses its stats.

The first plan made a hash of the audio the identity, so tags, renames and moves wouldn't change
it. That meant hashing every file, a separate audio range per format that other apps' tag
editors leave alone (MP3's trailing ID3v1, APEv2 and the Xing frame), and an identity rule that
could never change once stats were keyed on it. Half-copied files, ReplayGain tools that rewrite
MP3 frames, and duplicate rips each needed a rule of their own. That cost pays for one case, the
same music as separate copies on separate machines, and the owner doesn't have that case: every
machine points at the same files.

## Decision

A synced track is its path relative to the library root, normalized to NFC. Each
machine maps that to its own `paths` row by adding its root, so 0022's local IDs stay as they
are. A scan that finds files gone and files new matches them as moves, locally and for every
machine.

- **No case folding.** Every machine lists the same server, which returns the same names, so
  case can't differ between machines. NFC covers the one known difference, macOS and SMB
  spelling the same accented name two ways.
- **Locally**, `paths.path` is the absolute path in NFC, which every lookup normalizes to, so
  a name listed decomposed once and precomposed later is one path. `files.path` keeps the
  spelling the volume listed, which is what opens the file.
- **Move candidates** are `paths` rows with stats (plays, logged plays, a rating, a love or a
  playlist entry) whose file has left the index, from this scan or an earlier one, and every
  path with a track and no stats, whenever it arrived: one folder's scan can find a file
  arrive before another folder's scan finds it leave. `paths` gains the codec, sample rate,
  length in frames and title (in NFC), set by each read that succeeds, because a gone file
  can't be read again. A path a play created without a read has none of them and is never a
  candidate. Only a scan whose walk finished, and that read or removed something, matches.
- **Matching:** a gone path and a stat-less track are candidates when codec, sample rate and
  length in frames are equal. Alone in sharing those is no longer enough to match (ADR 0154). FLAC, ALAC and PCM
  (WAV, AIFF) count as one codec (amended 2026-11-07): converting between lossless codecs keeps
  every frame, so an ALAC `.m4a` converted to FLAC keeps its stats. A lossy codec only matches
  itself. Of the candidates, a gone and a new path that are alone in being the same path
  but for the extension match (a file converted in place), and then, of those left, a gone and a new path
  that are alone in also sharing a title (no title on either side never matches). Anything
  else isn't guessed.
- **Lost Stats**, a library health check (phase 19), lists every gone path with stats that no
  scan matched, and as its tracks every track without stats whose codec, rate and length
  match one, whenever it arrived. **Resolve Lost Stats…** shows one lost path at a time with
  the first 50 of those tracks, grouped in Swift rather than joined in SQL, since files that
  share a length would otherwise join every lost path with thousands of tracks: Give Stats
  moves the stats to the one picked (a pick a scan made stale moves nothing, and the next
  file shows), Dismiss hides the path until a
  read of its file clears that.
- **A match** gives the old `paths` row the new path and its facts, so the file keeps its ID,
  Date Added and stats. The row the scan added for the new path has no stats yet and is
  removed, with the file's index rows moved to the old ID and an import's empty counts for it
  deleted in the same transaction; this is
  the one exception to 0022's "rows are never deleted". Its ID can be handed out again, which
  is safe because no stat or history row refers to it; 23b emits the `move` event from the
  same matches, which the scan logs today.
- **Sync** carries a match as a `move` event with both relative paths. A machine that already
  made the same move, or has no row for the old path, does nothing with it. A machine with stats
  on both paths (it played the new path before the event arrived) merges them by phase 23's
  rules.
- **A move list** is the second source of moves (amended 2026-11-07), for a conversion the
  owner runs with a script that knows each file's old and new path: about 17,600 ALAC `.m4a`
  files converted to FLAC beside them. **File ▸ Import Moves…** reads a list outside the music
  folders, one line a file, `<old absolute path>\t<new absolute path>\n`, spelled as the volume
  lists them, written once the new file is in place and the old one gone. It runs on the scan
  queue, between scans and syncs, in transactions of 1,000 lines, and reads nothing but the
  list: of the music it only asks whether a file exists. Paths compare in NFC, as `paths` does.
  Each line takes one of these:
  - **The old path has no row** and the new one has stats: a scan matched the move, or the list
    was imported before. Already done; nothing changes. With no stats on the new path either, the
    old path was never in the library, and the line is a problem.
  - **The old path has a row**: it takes the new path through the code a sync `move` takes, so
    the file keeps its ID, Date Added, plays, history, rating, opinion and playlist entries, and
    the move is logged for the other Macs as a scan's match is. A new path with a track and no
    stats is a plain move. A new path with stats of its own merges them by phase 23's rules, as
    a move arriving after the new path was played does.
  - **The old path still has a file in the index** (no scan since the conversion): the index
    lets it go as a scan that found it gone would, then moves it, so the next scan finds nothing
    gone. When the old file is still on disk the line is a problem and nothing changes.
  - **The new path has no row** (no scan has seen it): the old row takes the new path, as a sync
    move to a path this machine hasn't scanned does, and the stats wait there for the scan,
    which stores the file under that row. The row drops the old file's codec, rate, length and
    title, which describe a file no longer there: with them it would be lost, and a move
    candidate for any other track of that length, until the scan. A sync move to a path not
    scanned drops them too, being the same code.
  So importing before or after the rescan ends the same. A line that doesn't parse, whose new
  file isn't on disk, or whose old path is unknown is a problem, listed by line number in the
  Problems window, and the other lines go on. A sheet says how many moved, merged and were
  already done.
- **One function** gives an old row its new path for a sync `move` and for a move list:
  `takeMove`, beside the merge rules it calls. The two differ only before it: a sync move with
  the old file still in the index waits for this Mac's scan, since a log can't vouch that the
  file left; a move list checks the disk, and lets the file go.
- Users who point machines at separate copies of their music don't share stats, unless the
  relative paths happen to match. Settings say so beside the sync folder.

## Alternatives considered

- **Absolute path** — rejected: the mount point differs between machines.
- **A SHA-256 of the whole file** — rejected: every tag edit changes it.
- **A SHA-256 of the audio, whole or sampled** — rejected for the costs in Context. It would
  have tracked moves done between scans with the file's content rather than its tags, and would
  have kept stats for separate copies, a case this library doesn't have.
- **An ID tag written into each file** — rejected: only `TagWriter` writes music files, and only
  for an edit the user confirmed.
- **MusicBrainz IDs** — rejected: only files tagged with Picard have them.
- **Acoustic fingerprints** — rejected: a new dependency, and fuzzy matches can merge two
  recordings.
- **FLAC's STREAMINFO MD5 as a move tie-break** — rejected: only FLAC has it and some encoders
  write zeros. The title tie-break works for every format.
- **Case-insensitive paths** — rejected: not needed with one server, and a case-sensitive share
  can hold two files whose names differ only by case.

## Consequences

The common scan, with nothing moved, reads no audio and matches nothing. A mistake in move
matching costs one file's stats rather than many. A reorganize that renames and retags at once
(Picard renaming the whole library) can match on frames alone only where the length is unique,
so the rest waits in the health report; an MP3 without a Xing or VBRI header has its length
estimated in steps of 1152 frames, so MP3s share lengths more often than lossless files. A different song saved over an old path takes the old song's stats,
and a re-rip saved at the same path keeps them. Machines that use separate copies of the music
share nothing. If that becomes a real setup, a hash of the audio is the alternative to revisit.
