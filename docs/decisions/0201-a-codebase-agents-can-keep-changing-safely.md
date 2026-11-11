# 0201. A codebase agents can keep changing safely: threat model rows, new checks, DeviceOutput

- **Date:** 2026-11-11
- **Status:** accepted
- **Amends:** [0025](0025-threat-model.md) (rows 66 to 76, and a Soulseek peer among those who
  attack)
- **See also:** [0027](0027-adversarial-testing.md) (the mutation scores),
  [0146](0146-staged-tag-writes.md), [0147](0147-moving-downloads-into-the-library.md),
  [0156](0156-replacing-an-album-at-its-own-paths.md), [0164](0164-keep-files-organized.md),
  [0142](0142-library-snapshots.md), [0181](0181-snapshots-keep-the-state-and-config-files.md),
  [0193](0193-approving-safe-matches-unasked.md),
  [0198](0198-the-library-profile-export.md),
  [0199](0199-an-import-deletes-what-it-replaces-without-the-finder.md)

## Context

Phase 84 reviewed the tree for what makes the next phases cheaper and safer for agents to
change. Three of its findings need a record: the threat model, last amended by ADR 0145, had no
rows for what phases 55 to 83 built on music-recommender's downloads, on snapshots and on the
profile export; `./scripts/check` gained steps whose limits a reader should know before trusting
them; and `DeviceOutput.swift` had 27 fix commits, most of one kind.

For the threat model, the review asked of each new entry point: can a tag value or a service
reply name a path outside the library or the staging folder, through `..`, an absolute path or
a link? Can a restored snapshot carry a secret or write outside the app's folders? Does the
export send only what ADR 0198 lists?

## Decision

### The threat model's new rows

ADR 0025 gains rows 66 to 76, and a fifth attacker: **a Soulseek peer, through the service**.
The peer chose the files music-recommender downloaded, so their bytes, names and tags are a
hostile file's, and their names reach the service's replies. The service is a LAN device too
(row 65), so a whole reply can be spoofed. Each row names its tests. The gaps the review found,
each fixed with a test that fails without the fix:

- **Staged file names (row 67).** The lossy-origin check and the sizes measured after a tag
  write joined the service's names to the staging folder unchecked. `DownloadJob.stagedFiles`
  is now the one place a staged name is checked, with the one `isRelativeInside`, which
  `ImportJobs` and `StagedAlbum` each had a private copy of; everything that reads or moves
  staged files takes them from there.
- **An upgrade's old paths (row 68).** Only the index's having no row for `library/../x` kept
  one from naming a file outside the share. Each is now held to `isRelativeInside` where it's
  decoded, where the index looks it up and where an import starts.
- **The Trash and the delete (row 71).** An old file swapped for a folder was deleted with what
  it held, and a set-aside name read back from the ledger could name any file in the share.
  Only a regular file goes now, and a set-aside one only by the import's own
  `.upgrade-<job>-<n>` in the library folder.
- **Approving unasked (row 72).** A reply calling a job clean was enough. Each staged file must
  now carry the job's release id as the player reads it.
- **Tag-derived names (row 73).** The extension skipped `safeName`, and one past 255 bytes
  trapped in it. It's held to the same rule now, cut to 16 bytes.
- **The snapshot write (row 74).** The writer's files were closed only in a `deinit`, with
  `try?`, so a close that failed on a full disk left a snapshot taken for whole. The close is
  checked now. The index's copy stays mode 0644, like the index: a listing, not a secret.
- **Restore (row 75).** It read the snapshot and its copies by path wherever they were: a link,
  a hard link to another file, a share, or a gzip that unpacks until the disk is full. The
  snapshot's folder must now be local, the files regular with one name, and the unpacked index
  at most 4 GiB.
- **The profile export (row 76).** It wrote wherever the save panel pointed, a music file or a
  link included. Both are refused now. Its keys were right; tests now pin them.

Two smaller findings went with them: a stale Approve sheet's claim that couldn't be given back
was dropped with `try?`, and is now said in the refusal; and the `try?` and unchecked sendables
in these files have their comments.

A name that fails its check doesn't fail the job's decode: a page of jobs decodes whole, so
one bad name would hide every job, and before a job is staged its names are the peer's. The job
is listed with the reason, as one with a bad `staged_path` already was. An old path does fail
the decode: the service makes those from the player's own index, which holds none.

### The new check steps and their limits

Each step fails a new case and lists today's in an allowlist that only shrinks.

- **`size`** fails a `.swift` file under `Sources` over 1,000 lines. A file already over is
  listed with its length as a ceiling, which a split lowers and nothing raises, and an entry at
  or under 1,000 fails. It counts lines, not what a change has to read: a 900-line file of one
  concern passes, and so does a function hundreds of lines long. `Tests` isn't measured, though
  six test files are over; the owner can widen it.
- **`trycomment`** fails a `try?` with no comment on its line or in the `//` run above it, or
  above an earlier line of the statement it continues. Any comment passes: a script can't judge
  a reason, so the review reads it. Its allowlist counts sites by file, not by line, so moving
  code doesn't churn it. Sites are found with a word boundary, `\btry\?`; the plain pattern also
  matched `Entry?`.
- **`unchecked`** fails an `@unchecked Sendable` or `nonisolated(unsafe)` whose comment names
  no guard: a lock, a queue, a semaphore, a condition, a serial order, the main actor, queue or
  thread, one thread, a value set once, or an immutable one. It sees that a guard is named, not
  that the code holds it.
- **`map`** fails a path that `docs/map.md` names in backticks under `Sources/`, `Tests/`,
  `scripts/`, `docs/` or `Support/` that doesn't exist, skipping placeholders with `<`, `>`, `*`
  or `{`; a Tiers row that `arch.swift`'s `allowed` doesn't have, or a tier with no row; and a
  folder `Sources/<Tier>/<Name>` that no target in `Package.swift` has as its path. The phase
  asked for a module folder that isn't in the map to fail. That would make map.md a hand-kept
  list of modules, a second copy of `Package.swift` that goes stale (principle 1), so the map
  lists none and the step checks the folders against the package instead. It can't tell whether
  the map's prose is still true.

### What DeviceOutput's fixes had in common

Its fix commits fell mostly into four groups. The largest, about ten of 29, came from one cause: the
control thread's pass, the caller's posts and the IO proc's consumed count were ordered only by
wall-clock timing. Their tests passed or failed by timing, and two of the fixes shipped with none.
The cure is a control thread that tests can step: an internal `ControlSeam` (its own thread, the
consumed count, the clock, and a hook after each chunk of a refill), with the thread's loop `wait()`
then `step()` in a file of its own, and the group's regression tests rewritten on it, a wall-clock
smoke test kept in each area. Nothing the IO proc reaches changed.

The other groups are a device lost and returning (7), the format and DoP (7), and a file that
ended early (3). Each already has tests through the null device's step failures. One
`ControlState` enum for the flags they share (`returnTo`, `returnDue`, `pausing`, `running`,
`drainedAt` and the first-sound target) is the next candidate, once the stepped machine has held.

## Alternatives considered

- **Refusing a job whose staged names fail at its decode.** Rejected: the job list decodes a
  page at a time, so one job would hide the rest, and a peer names the files before staging.
- **Requiring an upgrade's old files to be in the library folder.** Deferred to the owner:
  ADR 0147 lets an upgrade replace an album the owner keeps in another watched folder, which
  this would refuse. They're held to the share and to the index's tracks of the release.
- **Holding the export's destination to a folder outside every watched folder.** Rejected: the
  owner may keep the file anywhere, and the risk is replacing a music file, which the index
  check covers.
- **A module inventory in map.md, checked against the folders.** Rejected above, under `map`.

## Consequences

A job the service names a file of outside its folder, or an old path outside the share, is
shown and never approved. An approval unasked needs files the player tagged with the release,
so a job whose staged write didn't reach every file is left for the owner. A snapshot over
4 GiB unpacked can't be restored. The profile can't be saved over a library file. A swap
between a check by `lstat` and the call after it is still open (rows 14 and 71): macOS has no
call that does both. Every phase that adds an entry point still adds its row to ADR 0025.
