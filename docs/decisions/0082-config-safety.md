# 0082. A config with problems never empties the library

- **Date:** 2026-11-03
- **Status:** accepted
- **Amends:** [0015](0015-config-file.md), [0060](0060-rescan-interval-popup.md)

## Context

On the owner's mbp2026, a stale `appearance.nowPlaying` line (the key went in 4d0a177) failed
the config parse. A file with any problem applied nothing, so every setting stayed at its
default, and `library.watchedFolders` defaults to `[]`. The track list was empty, yet the
owner's index still showed 43,382 tracks, 11,169 plays and 149 ratings.

The launch path: `applicationDidFinishLaunching` reads the config, loads the browser, and once
the first rows draw (or the list is empty) `interactive()` calls `LibraryWatcher.start` with
`settings[\.watchedFolders]`, the default `[]`. `start` found every folder (there were none),
so it called `removeFiles(outside: [])`, which deletes every row of `files`, and of `tracks`
by cascade. So files were deleted. A copy of the bench index launched the same way here went
from 43,000 files and 42,964 tracks to 0 within seconds.

What survived is keyed by path, not by file ([ADR 0008](0008-library-schema-identity-and-stats-by-path.md)):
`paths`, `plays`, `ratings`, `loved`, `history` and `playlist_entries`, which are kept for a
folder added again. The 43,382 the owner counted is most likely the `paths` table, or Library
Health's Lost Stats, which lists every such path. That is also why the list was empty: the rows
it shows come from `tracks`. The removal writes nothing to the sync log, so the other Macs
weren't affected, and `removeFiles` also cleared each root's finished whole scan, so the first
launch after the config was fixed scanned the NAS folder whole and put the files back under
their old path IDs, with their stats.

## Decision

- **The watcher starts only on watched folders the file gives.** `ConfigStore` keeps which keys
  the file, or a change in the app, gave. `fileValue(_:)` returns a setting's value only then,
  never a default, and `startedWatcher` starts the watcher only on
  `fileValue(\.watchedFolders)`. While the file is blocked, gone, or doesn't name the key, the
  watcher stays off, which logs why: no scan, no FSEvents, and no removal. A fix that gives the
  folders counts as a change of the key even when the value is the same, so the watcher starts
  then. An edit that breaks the file while the app runs keeps what the file gave before, so the
  watcher keeps running on the real folders. A new file the app writes gives every default in it.
  A file that applies but doesn't name the key keeps the watcher off too, and the banner says so.
- **The watcher never removes files for no folders.** `start` skips the removal outside the
  folders when the list is empty, so a deleted or lost config, which the app replaces with one of
  `[]`, never empties the index, at that launch or the next. Stop Watching on the last folder,
  the one user action that means "no folders", removes its files through its own call
  (`stopWatching` → `LibraryWatcher.removeEveryFile`).
- **While a problem blocks the file, the app's changes are refused**, with an error naming the
  problem, and nothing is kept to write later. Memory holds defaults then, so a change built on
  them is wrong: adding a folder would give `[X]` where the file has A and B, the watcher would
  remove A's and B's files, and the patch written over the fix would drop them from the file.
  The same holds for every other key, most of all the output device, hog mode and digital
  volume the app writes by itself from the device in use, and for the shortcuts: a change
  waiting for the fix would replace the user's own value in the fixed file. Refusing keeps the
  rule simple: the file wins. Changes still wait, as before, on a failed write or on an empty
  read being confirmed, where memory holds the file's values.
- **Unknown keys don't block the file.** An unknown setting, or an unknown shortcut slot, is a
  problem tagged with its key path (`ConfigProblem.obsoleteKey`). It's listed in the banner and
  skipped; every other key applies, and changes in the app are written as patches, which change
  only their own key's text. So no default is written over a value in the file, and the unknown
  line stays until the user removes it.
- **Every other problem still applies nothing.** Bad JSON, a bad value for a known key, a key
  set twice, a shortcut the check refuses, or a sync folder inside a watched folder: the file
  applies nothing, as before. A bad value is usually a half-typed edit, and the app writes some
  keys itself, so writing around it could replace the line being typed with a value the app
  chose. The launch is safe either way, since a blocked file gives no watched folders.
- **Remove Obsolete Setting** in the banner (Remove Obsolete Settings for several) edits the
  file's text: each unknown key's member, its line, a `//` comment after it on that line, and the
  `//` lines directly above it, up to a blank line or anything else, go. Every other byte stays.
  When the removed key was last and the file has no comma after its last entry, the comma before
  it goes too; a file that ends its entries with commas keeps doing so. Nested keys (a shortcut's
  slot) are removed inside their object the same way. It writes only the config file. A comment
  directly under the opening brace, with no blank line before the key, is taken as the first
  key's own, since that's how a new file writes each key's comment; a header comment needs a
  blank line under it to stay.
- **Never, for a network folder's rescans** (34.4): `pollIntervalMinutes` is `null`. The folder
  is rescanned only by Rescan or Rescan All, and after a share moves, since its files are then
  at new paths. Never also skips the launch rescan `library.rescanNetworkFoldersAtLaunch` asks
  for, because the owner chose it for this folder. A folder whose last whole scan didn't finish
  is still scanned at launch, as today, or its index would stay incomplete until someone thought
  to rescan it. The value is written as `null`, not left out, since every key but the share is
  required.

## Alternatives considered

- **Only skip the removal for an empty list** — rejected alone: a blocked file's defaults, or a
  change built on them, can be a non-empty list that still isn't the user's. It's one of the two
  rules, beside gating on where the value came from.
- **Queue changes on a blocked file and write them on the fix, as before** — rejected: see
  above; the fixed file's own values would lose to changes made against defaults.
- **Apply the valid keys when a known key has a bad value too** — rejected for now, for the
  writes above; the banner's wording says which kind of problem the file has.
- **Drop unknown keys from the file on the next save** — rejected: the user's line would go
  without their say. Remove Obsolete Setting does it when asked.
- **`0` for Never** — rejected: a magic number inside the range's type; `null` is the format's
  own "none", as `output.deviceUID` uses it.

## Consequences

- `--scan` and the other command-line modes stay strict: any problem, an unknown key included,
  fails them, since they have no banner to show a skipped key.
- `--report-launch` prints "launched" at once when the watcher doesn't start, so Bench doesn't
  wait for scans that won't come.
- While the file is blocked, toggling a setting, picking an output or changing a shortcut shows
  an error until the file is fixed, and the device in use isn't written to the config.
