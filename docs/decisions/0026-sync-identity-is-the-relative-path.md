# 0026. Sync identifies a track by its path relative to the library root, and scans detect moves

- **Date:** 2026-11-01
- **Status:** accepted
- **Amends:** [0022](0022-stable-track-identity-and-play-timeline.md)

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
- **Matching:** a gone path and a stat-less track match when codec, sample rate and length in
  frames are equal and no other gone path or stat-less track shares them. Where several do, a gone and a new path
  that are alone in also sharing a title match (no title on both counts as the same). Anything
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
