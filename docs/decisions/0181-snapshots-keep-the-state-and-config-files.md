# 0181. Snapshots keep the state and config files

- **Date:** 2026-11-09
- **Status:** accepted
- **See also:** [0142](0142-library-snapshots.md) (the snapshots and the restore),
  [0137](0137-the-discogs-token.md) and [0144](0144-the-service-token.md) (the two secrets),
  [0166](0166-a-stale-state-key-drops-only-itself.md) (reading an older state file),
  [0025](0025-threat-model.md) (rows 58 and 65)

## Context

A snapshot kept only `library.sqlite`. The owner lost the whole of `state.json`, every window
frame, panel size, column and toolbar item, and no copy of it was anywhere. `config.json` has
the same exposure: it's edited by hand, and a bad edit or a lost disk loses it. It also holds
the two secrets, which must never leave it.

## Decision

- **What a snapshot holds.** Beside `library-<name>.sqlite.gz`, `state-<name>.json` and
  `config-<name>.json`, where `<name>` is the index's: the day, or the day and time for one
  before a restore. They are plain JSON, a few KB each, so they aren't compressed. Settings
  lists the index's file only; the copies go with it.
- **The config file's copy has no secret.** `ConfigSecrets.removed` takes out every member
  whose key is a setting of kind secret, from the schema, each time it's set. Comments go too,
  since a token commented out is still a token, and so do trailing commas and the blank lines
  they leave; every other member stays as written. The copy is written at mode 0600 all the
  same. A config file that isn't a JSON object can't have its secrets told from the rest, so the
  snapshot keeps no copy of it, and says so in the log; it never copies the file as it is. A
  state or config file that isn't there is no copy, not a failure.
- **One write.** The index's file and each copy are written whole under their own hidden
  partial names first, then renamed: the index's first, so a copy is never in the folder without
  its snapshot. A file with no copy now deletes the copy an earlier snapshot of the day left, so
  a snapshot holds only what its own write copied. A failure before the renames leaves no
  partial. Rotation deletes a snapshot's copies before its index file, so a delete that fails
  leaves no copy without its snapshot. Only names made from a snapshot's parsed name are
  deleted.
- **Restore… takes all three.** It copies the snapshot's state and config files to
  `state.json.restoring` and `config.json.restoring` beside the live files, then the snapshot
  before the restore keeps the current index and files, the config's without its secrets, as
  every snapshot does. A snapshot without copies, as those written before this, restores the
  index only and leaves the live files as they are. Before it copies anything, a restore checks
  that the live config file reads as a JSON object, since otherwise its tokens can't be kept,
  and refuses with nothing pending when it doesn't.
- **The secrets stay as they are.** At launch, `ConfigSecrets.kept` gives the restored copy
  each secret the live config file sets, at the value it has there, and no other; with no live
  file, none. The restore never loses or changes a token, and a token the live file doesn't set
  isn't set by the restore either.
- **At launch, before the index opens and before `ConfigStore` and `StateStore` read their
  files**, so the swap moved to the start of the launch. The tokens are merged into
  `config.json.restoring` before anything moves: a config file that broke since Restore… leaves
  everything as it was, the restore waiting, and says why. Then the index is swapped as before,
  with its move back, and the two files are renamed over the live ones. When a file's rename
  fails after the index's swap, the marker stays and the next launch renames the files left,
  as it finds the index already in place. The marker goes once all three are in place.

## Consequences

- A restored state file from an older build loses only its keys that no longer match
  (ADR 0166). A restored config file from an older build can have a key this build doesn't
  take; `ConfigStore` shows that in its banner, with Remove Obsolete Settings, as for any edit.
- A restored config file has no comments: the setting comments the app writes come back only
  for a setting the app sets again. That is the cost of a copy no commented-out token survives.
- While a restore waits, `config.json.restoring` sits beside `config.json`, at mode 0600, and
  after the merge it holds the live tokens, as `config.json` does.
- The state file is saved again when the app quits for the restore, after the snapshot before
  the restore took its copy, so that copy can lack the last few seconds of layout.
- AGENTS.md's app state and secrets sentences say a snapshot's copy of `config.json` never
  holds a secret; rows 58 and 65 of the threat model name the tests.
